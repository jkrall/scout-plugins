require 'rubygems'
require 'set'
class MysqlMonitoring< Scout::Plugin
  ENTRIES = %w(Com_insert Com_select Com_update Com_delete Com_replace).to_set
  def build_report
    # need the mysql gem
    begin
      require 'mysql'
    rescue LoadError => e
      return errors << {:subject => "Unable to gather Mysql query statistics",
                          :body => "Unable to find the mysql gem. Please install the gem (sudo gem install mysql)" }
    end
    
    user = @options['user'] || 'root'
    password, host, port, socket = @options.values_at( *%w(password host port socket) ).map { |v| v.to_s.strip == '' ? nil : v}

    now = Time.now
    begin
      mysql = Mysql.connect(host, user, password, nil, port.to_i, socket)
    rescue Mysql::Error => e
      return errors << {:subject => "Unable to connect to MySQL Server.",
                        :body => "Scout was unable to connect to the mysql server with the following options: #{@options.inspect}: #{e.backtrace}"}
    end
    result = mysql.query('SHOW /*!50002 GLOBAL */ STATUS')

    rows = []
    total = 0
    result.each do |row| 
      rows << row if ENTRIES.include?(row.first)

      total += row.last.to_i if row.first[0..3] == 'Com_'
    end
    result.free

    report = {}
    rows.each do |row|
      name = row.first[/_(.*)$/, 1]
      report[name] = calculate_counter(now, name, row.last.to_i)
    end
    report['total'] = calculate_counter(now, 'total', total)

    report(report) if report.values.compact.any?
  end

  private
  def calculate_counter(current_time, name, value)
    result = nil

    if (mem = memory(name)) and mem.is_a?(Hash)
      last_value = mem['value'].to_i
      last_time = Time.parse(mem['time'])
      # We won't log it if the value has wrapped
      if value >= last_value
        elapsed_seconds = last_time - current_time
        elapsed_seconds = 1 if elapsed_seconds < 1
        result = value - last_value
        # calculate per/second
        result = result / elapsed_seconds.to_f
      end
    end

    remember(name => { 'time' => current_time, 'value' => value })

    result
  end
end