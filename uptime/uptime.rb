class Uptime < Scout::Plugin
  def build_report
    if `uptime` =~ /up +([^,]+)/
      report :uptime => $1
    else
      raise "Unexpected output format"  
    end
  rescue Exception
    error "Couldn't use `uptime` as expected.", $!.message
  end
end