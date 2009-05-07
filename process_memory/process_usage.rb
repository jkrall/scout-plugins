class ProcessUsage < Scout::Plugin  
  MEM_CONVERSION = 1024
  
  def build_report
    if @options["command_name"].nil? or @options["command_name"] == ''
      return error(:subject => "Please specify the name of the process you want to monitor.")
    end
    ps_command   = @options['ps_command'] || "ps axucww"
    ps_output    = `#{ps_command}`
    fields       = ps_output.to_a.first.downcase.split
    memory_index = fields.index("rss")
    highest      =
      ps_output.grep(/#{Regexp.escape(@options["command_name"])}\s+$/i).
                map { |com| Float(com.split[memory_index]).abs }.max
    if highest
      report(:memory  => (highest/MEM_CONVERSION).to_i)
    else
      error(:subject => "Command not found.",
            :body    => "No processes found matching #{@options['command_name']}.")
    end
  rescue
    error(:subject => "Couldn't use `ps` as expected.",
          :body    => $!.message)
  end
end
