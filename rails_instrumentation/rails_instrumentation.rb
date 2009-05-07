class RailsInstrumentation < ScoutAgent::Plugin
  def build_report
    begin    
      # intialize our analyzer 
      analyzer = RailsAnalyzer.new
      
      ### pull in the reports from the message queue and analyze each report
      each_queued_message do |message, time|
        report(message.reject { |k,v| k == 'queries'}) # remove the top-level queries key/value...only needed for analysis
        analyzer.analyze(message)
      end
      # create hints based on analysis
      analyzer.finish!
      analyzer.hints.each { |h| hint(h) }
    rescue Exception => e
      p e
      p e.backtrace
      error(:subject => e, :body => e.backtrace)
    end
  end
end

require "digest/md5"

# Accepts a Query Array (which contains details on an SQL Query). This is a wrapper
# to make SQL queries easier to work with.
class SqlQuery
  attr_accessor :query_type, :extra, :key, :rows, :table, :sql, :sanitized_sql, :duration, :time_of_day,
                :explain_issues
  
  #####################
  ### Class Methods ###
  #####################
  
  # Initializes a new +SqlQuery+ and analyzes the query. Returns a 3 element Hash:
  def self.analyze(query_array)
    query = new(query_array)
    query.analyze_explain
    query
  end
  
  # From Rails Query Review Plugin
  def self.sanitize_sql(sql)
    new_sql = sql.dup
    new_sql.gsub!(/\b(?:0x[0-9A-Fa-f]+|\d+)\b/, "?")
    new_sql.gsub!(/'(?>[^']*)(?>''[^']*)*'/,    "?")
    new_sql.gsub!(/"(?>[^"]*)(?>""[^"]*)*"/,    "?")
    return new_sql
  end
  
  ########################
  ### Instance Methods ###
  ########################
  
  def initialize(query_array)
    # Sets EXPLAIN output to specific attributes for easier access
    explain_hash = query_array.last
    if explain_hash.is_a?(Hash)
      self.query_type = explain_hash['type']
      self.extra      = explain_hash['extra'] || ''
      self.key = explain_hash['key']
      self.rows = explain_hash['rows']
      self.table = explain_hash['table']
    end
    self.sql = query_array[1]
    self.sanitized_sql = self.class.sanitize_sql(sql)
    self.duration = query_array.first || 0
    self.time_of_day = query_array[2]
    self.explain_issues = Array.new
  end
  
  # True if any EXPLAIN output. 
  def explained?
    query_type or extra or key or rows or table
  end
  
  # Returns true if this Query has..issues...it's either slow or slow w/bad things
  # found when analyzing the EXPLAIN output.
  #
  # If a query isn't slow, but has EXPLAIN issues, it's not a problem because it isn't 
  # slow yet. We only want to create hints for problems, not for things that are 
  # likely to be ignored.
  def problems?
    slow? or (slow? and explain_issues?)
  end
  
  def explain_issues?
    explain_issues.any?
  end
  
  # Returns +true+ if the query duration exceeds RailsAnalyzer::MAX_QUERY_TIME.
  def slow?
    duration > RailsAnalyzer::MAX_QUERY_TIME
  end
  
  # Analyzes the explain output of the query. If any issues are detected, they are added to the
  # explain_issues Array.
  def analyze_explain
    analyze_query_type
    analyze_key
  end

  def analyze_query_type
    case query_type
    when "system", "const", "eq_ref" 
      # these are good
    when "ref", "ref_or_null", "range", "index_merge" 
      # also good
    when "unique_subquery", "index_subquery"
      #NOT SURE
    when "index" 
      self.explain_issues << "using a full index tree scan (slightly faster than a full table scan)" if extra.include?("using where")
    when "all" 
      self.explain_issues << "using a full table scan" if extra.include?("using where")
    end
  end

  def analyze_key
    return unless explained?
    if self.key == "const"
      # good
    elsif self.key.nil? && !self.extra.include?("select tables optimized away")
      self.explain_issues <<  "not using an index, which meant scanning #{self.rows} rows in the <em>#{table}</em> table"
    end
  end  
end # SqlQuery

class RailsAnalyzer
  # in milliseconds
  MAX_QUERY_TIME = 50
  # if more than this number of queries are generated from an action, a hint is generated. 
  MAX_QUERIES = 10
  
  attr_accessor :actions, :time, :actions_with_too_many_queries, :hints
  
  def initialize
    self.hints  = Array.new
    reset!
  end
  
  # Wraps up the analysis, generating hints and reseting counts.
  def finish!
    create_query_hints
    create_too_many_queries_hints
  end
  
  # Analyzes a Scout report, populating +actions+ with actions & associated problem queries and 
  # +actions_with_too_many_queries+ with actions that have too many queries.
  #
  # Queries is an Array of Arrays of Arrays:
  # - Top Level => An element for each request generated for the +action+.
  #                For example, if the users/show action processed 5 requests, there would be 5 array elements.
  # - 2nd Level => An element for each query of the request. 
  #                For example, if the request had 20 queries, there would be 20 elements
  # - 3rd level => An element that corresponds to specific attributes of the query.
  #                These SQL Queries contain the following elements at each index:
  #                0 - Length of query in MS
  #                1 - SQL
  #                2 - Time of Day of Query
  #                3 - EXPLAIN output in a Hash
  def analyze(o)
    # grab the time the report was generated
    self.time=o.delete('time')
    actions = o['actions']
    actions.each_pair do |action,data|
      request_groups=data.delete('queries') 
      next if request_groups.nil? # If no queries, move on to the next action
      request_groups.each do |queries|
        # Look at each query, analyzing it for problems. If any problems occur,
        # add the query to the list of problem queries for the +action+.
        queries.each do |(time, query_lookup_id, *rest)|
          # queries are abstracted into a lookup table, so we pull in the
          # actual query from this lookup table before analyzing it.
          query_and_time = [time, o['queries'][query_lookup_id], *rest]
          analyzed_query = SqlQuery.analyze(query_and_time)
          add_problem_query(action,analyzed_query) if analyzed_query.problems?
        end # queries.each
        analyze_too_many_queries(action,queries)
      end # request_groups
    end # o.each_pair
  end # analyze
  
  # Creates a hint for each problem query
  def create_query_hints
    if actions.any?
      actions.each do |action,queries|
        queries.each do |query|
          duration=query.duration.to_i
          if query.explain_issues? # slow & explain issues. we can give more details.
            importance = 0
            importance += 1 if duration > 100
            importance += 1 if duration > 200
            importance += 1 if duration > 300
            importance = 3 if importance > 3 # importance maxes out at 3
            add_hint(
                  :title => "A #{duration}ms query in the #{query.table} table may be able to be optimized.",
                  :description => "The query #{query.explain_issues.size > 1 ? 'has the following issues:' : 'is'} #{query.explain_issues.join(', ')}",
                  :grouping => action,
                  :token => "explain #{query.sanitized_sql}",
                  :additional_info => query.sanitized_sql,
                  :importance=>importance,
                  :tag_list=>'slow,explain_issues'
                  
            )
          else # just slow
            # calculate importance
            importance = 0
            importance += 1 if duration > 100
            importance += 1 if duration > 200
            importance += 1 if duration > 300
            add_hint(
                  :title => "A slow query occurred (#{duration} ms).",
                  :description => "This query exceeds the maximum specified duration of #{MAX_QUERY_TIME}ms.",
                  :grouping => action,
                  :token => "slow #{query.sanitized_sql}",
                  :additional_info => query.sanitized_sql,
                  :importance=>importance,
                  :tag_list=>'slow'
            )
          end
        end
      end
    end # actions.any?
  end
  
  # Creates a hint for each action that exceeded the maximum num. of queries. 
  def create_too_many_queries_hints
    return unless actions_with_too_many_queries.any?
    actions_with_too_many_queries.each do |q|
      title = "The #{q[:action]} action has too many SQL Queries."
      count,time=q[:query_count],q[:db_time].to_i
      description = "This action exceeded the maxiumum number of SQL queries with #{count} queries totaling #{time}ms of DB time."
      # calculate importance
      importance = 0
      importance += 1 if count > 15
      importance += 1 if count > 25
      importance += 1 if time > 100
      importance += 1 if time > 400
      importance = 3 if importance > 3 # importance maxes out at 3
      add_hint(:title => title,
           :description => description,
           :grouping => q[:action],
           :token => 'too many queries' + q[:query_count].to_s,
           :importance=> importance,
           :tag_list=>'too_many_queries'
          )
    end
  end
  
  def add_hint(options = {})
    options = {
      :time => time,
      :kind => :sql
    }.merge(options)
    options[:token] = Digest::MD5.hexdigest(options[:token])
    self.hints << options
  end
  
  def reset!
    self.actions                       = {}
    self.actions_with_too_many_queries = Array.new
  end
  
  # Adds the +ScoutPlugin::SqlQuery+ to the Array of slow queries for the +action+.
  def add_problem_query(action,analyzed_query)
    existing_queries = actions[action]
    if existing_queries and !existing_queries.find { |q| q.sanitized_sql == analyzed_query.sanitized_sql }
      actions[action] << analyzed_query
    else
      actions[action] = [ analyzed_query ]
    end
  end
  
  # Iterates thru each of the collections of SQL queries, generating a hint if 
  # the number of SELECT queries exceeds +MAX_QUERIES+.
  def analyze_too_many_queries(action,queries)
    query_count = queries.size
    if query_count >= MAX_QUERIES
      max_db_time = queries.inject(0) { |sum,q| sum + q.first }
      # add this action as one with slow queries.
      # If the action doesn't already exist in the Array, add it. 
      # Delete the existing action if it exists and its DB time is less than this +action+.
      # * The action exists,
      if actions_with_too_many_queries.find { |hash| hash[:action] == action }.nil? or actions_with_too_many_queries.delete_if { |hash| hash[:action] == action and hash[:db_time] < max_db_time}.is_a?(Hash)
        actions_with_too_many_queries << {:action => action, 
                                          :query_count => query_count, 
                                          :db_time => max_db_time
                                          }
      end # if actions_with_too_many_queries
    end # if query_count >= MAX_QUERIES
  end # analyze_too_many_queries
end

### Support

class Fixnum
  # TODO - Add me
  def commify
    self
  end
end
