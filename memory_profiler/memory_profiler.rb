class MemoryProfiler < Scout::Plugin
  def run
    mem_total = @options['total_memory'] / 1024
    mem_used = `ps -Ao rss`.split(/\n/)[1..-1].collect {|n| n.strip.to_i}.inject(0) {|c,i| c+i} / 1024
    mem_free = mem_total - mem_used
    mem_percent_used = (mem_used / mem_total.to_f * 100).to_i

    report = {}

    report['Memory Total'] = mem_total
    report['Memory Free'] = mem_free
    report['Memory Used'] = mem_used    
    report['% Memory Used'] = mem_percent_used

    { :report => report }
    
  rescue Exception => e
    body = "An error occurred profiling the memory:\n\n#{e.message}\n\n#{e.backtrace}"
    {:error => {:subject => "Unable to Profile Memory", :body    => body}}
  end
end
