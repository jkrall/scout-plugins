class MemoryProfiler < Scout::Plugin
  def build_report
    mem_total = option('total_memory').to_i
    mem_used = `ps -Ao rss`.split(/\n/)[1..-1].collect {|n| n.strip.to_i}.inject(0) {|c,i| c+i} / 1024
    mem_free = mem_total - mem_used
    mem_percent_used = (mem_used / mem_total.to_f * 100).to_i

    report 'Memory Total' => mem_total
    report 'Memory Free' => mem_free
    report 'Memory Used' => mem_used    
    report '% Memory Used' => mem_percent_used

  rescue Exception => e
    error(:subject => "Unable to Profile Memory",
          :body => "An error occurred profiling the memory:\n\n#{e.message}\n\n#{e.backtrace}")
  end
end
