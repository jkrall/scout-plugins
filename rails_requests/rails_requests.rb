require "time"

class RailsRequests < Scout::Plugin
  
  TEST_USAGE = "#{File.basename($0)} log LOG max_request_length MAX_REQUEST_LENGTH last_run LAST_RUN"
  
  def build_report

    begin
      require "elif"
    rescue LoadError
      begin
        require "rubygems"
        require "elif"
      rescue LoadError
        return error(:subject => "Couldn't load Elif.",
                     :body    => "The Elif library is required by " +
                                 "this plugin." )
      end
    end
    
    if option(:log).strip.length == 0
      return error(:subject => "A path to the Rails log file wasn't provided.")
    end

    report_data = { :slow_request_count => 0,
                :request_count => 0,
                :average_request_length => nil }
    
    last_completed = nil
    slow_requests = ''
    total_request_time = 0.0

    last_run = if option(:last_run) 
                  Time.parse(option(:last_run))
               else
                  memory(:last_run) || Time.now
               end
    remember(:last_run => Time.now)    
    
    date_format_regex = '\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\s+\w+\s+'
  
    Elif.foreach(option(:log)) do |line|
      if line =~ /\A#{date_format_regex}Completed in (\d+)ms .+ \[(\S+)\]\Z/        # newer Rails
        last_completed = [$1.to_i / 1000.0, $2]
      elsif line =~ /\A#{date_format_regex}Completed in (\d+\.\d+) .+ \[(\S+)\]\Z/  # older Rails
        last_completed = [$1.to_f, $2]
      elsif last_completed and
            line =~ /\AProcessing .+ at (\d+-\d+-\d+ \d+:\d+:\d+)\)/
        time_of_request = Time.parse($1)
        if time_of_request < last_run
          break
        else
          report_data[:request_count] += 1
          total_request_time += last_completed.first.to_f
          if option(:max_request_length).to_f > 0 and last_completed.first.to_f > option(:max_request_length).to_f
            report_data[:slow_request_count] += 1
            slow_requests += "#{last_completed.last}\n"
            slow_requests += "Time: " + last_completed.first.to_s + " sec" + "\n\n"
          end
        end # request should be analyzed
      end
    end
    
    # Create a single alert that holds all of the requests that exceeded the +max_request_length+.
    if report_data[:slow_request_count].to_i > 0
      count = report[:slow_request_count].to_i
      alert(:subject => "Maximum Time(#{option(:max_request_length).to_s} sec) exceeded on #{count} #{count > 1 ? 'requests' : 'request'}",
            :body => slow_requests)
    end
    # Calculate the average request time if there are any requests
    if report_data[:request_count] > 0
      avg = total_request_time/report_data[:request_count]
      report_data[:average_request_length] = sprintf("%.2f", avg)
    end
    report(report_data)
  rescue
    if $!.message == "undefined method `strip' for nil:NilClass"
      error(:subject => "Please provide the full path to the log file.",
             :body => "A full path to the Rails log file wasn't provided - you can specify the path in the plugin option.")
    else
      error(:subject => "Couldn't parse log file.",
              :body    => $!.message)
    end
  end
end
