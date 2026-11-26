module InputQueueSmoke
  def self.run(scene)
    thread=Win32API.new('kernel32','GetCurrentThreadId',[],'L').call
    post=Win32API.new('user32','PostThreadMessageW',['L','L','L','L'],'I')
    peek=Win32API.new('user32','PeekMessageW',['P','L','L','L','L'],'I')
    sleep_ms=Win32API.new('kernel32','Sleep',['L'],'V')
    tag=0x8351 # private, inert thread message (no HWND and no keyboard event)
    message="\0"*28
    3.times do |trial|
      48.times { raise 'PostThreadMessage failed' if post.call(thread,tag,0,0)==0 }
      sleep_ms.call(100) # make the scheduler late; it must not need idle time to drain
      frames=0
      3.times do
        Graphics.update
        frames+=1
        break if peek.call(message,0,tag,tag,0)==0
      end
      remaining=0
      while peek.call(message,0,tag,tag,1)!=0
        remaining+=1
      end
      puts "INPUT_QUEUE trial=#{trial} frames=#{frames} remaining=#{remaining}"
      raise "Messages left after three overdue frames: #{remaining}" unless remaining==0
    end
    puts "INPUT_QUEUE PASS #{ModLoader.input_queue_status}" if ModLoader.respond_to?(:input_queue_status)
  end
end
