require 'socket'
require 'pqueue'
require 'fiber'
include Socket::Constants

module QuartzTorrent

  # Callers must subclass this class to use the reactor. The event handler methods should be 
  # overridden. For data-oriented event handler methods, the functions write and read are available
  # to access the current io, as well as the method currentIo. Close can be called from
  # event handlers to close the current io.
  class Handler
    # Event handler. An IO object has been successfully initialized.
    # For example, a connect call has completed
    def clientInit(metainfo)
    end

    # Event handler. A peer has connected to the listening socket
    def serverInit(metainfo, addr, port)
    end

    # Event handler. The current io is ready for reading
    # If you will write to the same io from both this handler and the timerExpired handler,
    # you must make sure to perform all writing at once in this handler. If not then 
    # the writes from the timer handler may be interleaved. 
    #
    # For example if the recvData handler performs:
    #
    #  1. read 5 bytes   
    #  2. write 5 bytes   
    #  3. read 5 bytes   
    #  4. write 5 bytes   
    #
    #  and the writes in 2 and 4 are meant to be one message (say mesage 2 is the length, and message 4 is the body)
    # then this can occur:
    #   recvData reads 5 bytes, writes 5 bytes, tries to read 5 more bytes and is blocked
    #   timerExpired writes 5 bytes
    #   recvData continues; reads the 5 bytes and writes 5 bytes.
    #
    # Now the timerExpired data was written interleaved.
    def recvData(metainfo)
    end

    # Event handler. A timer has expired
    def timerExpired(metainfo)
    end

    # Event handler. Error during read, or write. Connection errors are reported separately in connectError
    def error(metainfo, details)
    end

    # Event handler. Error during connection, or connection timed out.
    def connectError(metainfo, details)
    end

    # Event handler. This is called for events added using addUserEvent to the reactor.
    def userEvent(event)
    end

    ### Methods not meant to be overridden
    attr_accessor :reactor

    def scheduleTimer(duration, metainfo = nil, recurring = true, immed = false)
      @reactor.scheduleTimer(duration, metainfo, recurring, immed) if @reactor
    end  

    def connect(addr, port, metainfo, timeout = nil)
      @reactor.connect(addr, port, metainfo, timeout) if @reactor
    end

    # Write data to the current io
    def write(data)
      @reactor.write(data) if @reactor
    end

    # Read len bytes from the current io
    def read(len)
      result = ''
      result = @reactor.read(len) if @reactor 
      result
    end

    # Shutdown the reactor
    def stopReactor
      @reactor.stop if @reactor
    end

    # Close the current io
    def close(io = nil)
      @reactor.close(io) if @reactor
    end

    def currentIo
      result = nil
      result = @reactor.currentIo if @reactor
      result
    end
    
    # Find an io by metainfo
    def findIoByMetainfo(metainfo)
      @reactor.findIoByMetainfo metainfo if metainfo && @reactor
    end

    def setMetaInfo(metainfo)
      @reactor.setMetaInfo metainfo if @reactor
    end
  end
  
  class OutputBuffer
    # Create a new OutputBuffer for the specified IO. The parameter seekable should be
    # true or false. If true, then this output buffer will support seek
    # at the cost of performance.
    def initialize(io, seekable = false)
      @io = io
      @seekable = seekable
      if seekable
        @buffer = []
      else
        @buffer = ''
      end
    end

    def empty?
      @buffer.length == 0
    end

    def append(data)
      if ! @seekable
        @buffer << data
      else
        @buffer.push [@io.tell, data]
      end
    end

    # Write the contents of the output buffer to the io. This method throws all of the exceptions that write would throw
    # (EAGAIN, EWOULDBLOCK, etc)
    def flush
      if ! @seekable
        while @buffer.length > 0
          numWritten = @io.write_nonblock(@buffer)
          @buffer = @buffer[numWritten,@buffer.length]
        end
      else
        while @buffer.length > 0
          @io.seek @buffer.first[0], IO::SEEK_SET
          while @buffer.first[1].length > 0
            numWritten = @io.write_nonblock(@buffer.first[1])
            @buffer.first[1] = @buffer.first[1][numWritten,@buffer.first[1].length]
          end
          # This chunk has been fully written. Remove it
          @buffer.shift
        end
      end
    end
  end

  # This class provides a facade for an IO object. The read method
  # on this object acts as a blocking read. Internally it reads 
  # nonblockingly and passes processing to other ready sockets
  # if this socket would block.
  class IoFacade
    def initialize(ioInfo, logger = nil)
      @ioInfo = ioInfo
      @io = ioInfo.io
      @logger = logger
    end

    attr_accessor :logger

    def read(length)
      data = ''
      while data.length < length
        begin
          @logger.debug "IoFacade: must read: #{length} have read: #{data.length}. Reading #{length-data.length} bytes now" if @logger
          data << @io.read_nonblock(length-data.length)
        rescue Errno::EWOULDBLOCK
          # Wait for more data.
          @logger.debug "IoFacade: read would block" if @logger
          Fiber.yield
        rescue Errno::EAGAIN, Errno::EINTR
          # Wait for more data.
          @logger.debug "IoFacade: read was interrupted" if @logger
          Fiber.yield
        rescue
          @logger.debug "IoFacade: read error: #{$!}" if @logger
          # Read failure occurred
          @ioInfo.lastReadError = $!
          if @ioInfo.useErrorhandler
            @ioInfo.state = :error
            Fiber.yield
          else
            raise $!
          end
        end
      end
      data
    end

    def write(data)
      # Issue: what about write, read, read on files opened for read/write? Write should happen at offset X, but reads moved to offset N. Since writes
      # are buffered, write may happen after read which means write will happen at the wrong offset N. Can fix by always seeking (if needed) before writes to the 
      # position where the write was queued, but this should only be done for files since other fds don't support seek. This is satisfactory for files opened
      # for write only since the file position will be where we expect so we won't need to seek. Same for read only. 
      @ioInfo.outputBuffer.append data
      @logger.debug "wrote #{data.length} bytes to the output buffer of IO metainfo=#{@ioInfo.metainfo}" if @logger
      data.length
    end

    def seek(amount, whence)
      @io.seek amount, whence if @ioInfo.seekable?
    end

    def flush
      @io.flush
    end
  end

  class WriteOnlyIoFacade < IoFacade
    def initialize(ioInfo, logger = nil, readError = "Reading is not allowed for this IO")
      super(ioInfo, logger)
      @readError = readError
    end

    def read(length)
      raise @readError
    end
  end

  class IOInfo
    def initialize(io, metainfo, seekable = false)
      @io = io
      @metainfo = metainfo
      @readFiber = nil
      @readFiberIoFacade = IoFacade.new(self)
      @lastReadError = nil
      @connectTimer = nil
      @seekable = seekable
      @outputBuffer = OutputBuffer.new(@io, seekable)
      @useErrorhandler = true
    end
    attr_accessor :io
    attr_accessor :metainfo
    attr_accessor :state
    attr_accessor :lastReadError
    attr_accessor :connectTimeout
    attr_accessor :outputBuffer
    attr_accessor :readFiber
    attr_accessor :readFiberIoFacade
    attr_accessor :connectTimer
    attr_accessor :useErrorhandler
    def seekable?
      @seekable
    end
  end

  class TimerManager
    class TimerInfo
      def initialize(duration, recurring, metainfo)
        @duration = duration
        @recurring = recurring
        @expiry = Time.new + @duration
        @metainfo = metainfo
        @cancelled = false
      end
      attr_accessor :recurring
      attr_accessor :duration
      attr_accessor :expiry
      attr_accessor :metainfo
      # Since pqueue doesn't allow removal of anything but the head
      # we flag deleted items so they are deleted when they are pulled
      attr_accessor :cancelled

      def secondsUntilExpiry
        @expiry - Time.new
      end
    end

    def initialize
      @queue = PQueue.new { |a,b| b.expiry <=> a.expiry }
    end

    def add(duration, metainfo = nil, recurring = true, immed = false)
      raise "TimerManager.add: Timer duration may not be nil" if duration.nil?
      info = TimerInfo.new(duration, recurring, metainfo)
      info.expiry = Time.new if immed
      @queue.push info
      info
    end
  
    def cancel(timerInfo)
      timerInfo.cancelled = true
    end

    # Return the next timer event from the queue, but don't remove it from the queue.
    def peek
      clearCancelled
      @queue.top
    end

    # Remove the next timer event from the queue and return it as a TimerHandler::TimerInfo object.
    def next
      clearCancelled
      result = @queue.pop
      if result && result.recurring
        add(result.duration, result.metainfo, result.recurring)
      end
      result
    end

    private 
    
    def clearCancelled
      @queue.pop while @queue.top && @queue.top.cancelled
    end
  end

  class Reactor
    class InternalTimerInfo
      def initialize(type, data)
        @type = type
        @data = data
      end
      attr_accessor :type
      attr_accessor :data
    end
  
    def initialize(handler, logger = nil)
      raise "Reactor.new called with nil handler. Handler can't be nil" if handler.nil?

      @stopped = false
      @handler = handler
      @handler.reactor = self

      # Hash of IOInfo objects, keyed by io.
      @ioInfo = {}
      @timerManager = TimerManager.new
      @currentIoInfo = nil
      @logger = logger
      @listenBacklog = 10
      @eventRead, @eventWrite = IO.pipe
      @currentHandlerCallback = nil
      @userEvents = []
    end

    attr_accessor :listenBacklog

    # Create a TCP connection to the specified host
    def connect(addr, port, metainfo, timeout = nil)
      ioInfo = startConnection(port, addr, metainfo)
      @ioInfo[ioInfo.io] = ioInfo
      if timeout && ioInfo.state == :connecting
        ioInfo.connectTimeout = timeout
        ioInfo.connectTimer = scheduleTimer(timeout, InternalTimerInfo.new(:connect_timeout, ioInfo), false)
      end
    end

    # Create a TCP server that listens for connections on the specified 
    # port
    def listen(addr, port, metainfo)
      listener = Socket.new( AF_INET, SOCK_STREAM, 0 )
      sockaddr = Socket.pack_sockaddr_in( port, "0.0.0.0" )
      listener.setsockopt(Socket::SOL_SOCKET,Socket::SO_REUSEADDR, true)
      listener.bind( sockaddr )
      @logger.debug "listening on port #{port}" if @logger
      listener.listen( @listenBacklog )
                 
      info = IOInfo.new(listener, metainfo)
      info.readFiberIoFacade.logger = @logger if @logger
      info.state = :listening
      @ioInfo[info.io] = info
    end

    # Open the specified file for the specified mode.
    def open(path, mode, metainfo, useErrorhandler = true)
      file = File.open(path, mode)

      info = IOInfo.new(file, metainfo, true)
      info.useErrorhandler = useErrorhandler
      info.readFiberIoFacade.logger = @logger if @logger
      info.state = :connected
      @ioInfo[info.io] = info
    end

    # Add a generic event. This event will be processed the next pass through the
    # event loop
    def addUserEvent(event)
      @userEvents.push event
    end

    # Run event loop
    def start
      while true
        begin
          break if eventLoopBody == :halt
        rescue
          @logger.error "Unexpected exception in reactor event loop: #{$!}" if @logger
          @logger.error $!.backtrace.join "\n" if @logger
        end
      end
    
      # Event loop finished
      @ioInfo.each do |k,v|
        k.close
      end

    end

    def stop
      @stopped = true
      @eventWrite.write "x"
      @eventWrite.flush
    end

    def scheduleTimer(duration, metainfo = nil, recurring = true, immed = false)
      @timerManager.add(duration, metainfo, recurring, immed)
    end  

    # Meant to be called from the handler. Adds the specified data to the outgoing queue for the current io
    def write(data)
      if @currentIoInfo
        # This is meant to be called from inside a fiber. Should add a check to confirm that here.
        @currentIoInfo.readFiberIoFacade.write(data)
      else
        raise "Reactor.write called with no current io. Was it called from a timer handler?"
      end
    end

    def read(len)
      if @currentIoInfo
        # This is meant to be called from inside a fiber. Should add a check to confirm that here.
        @currentIoInfo.readFiberIoFacade.read(len)
      else
        raise "Reactor.read called with no current io. Was it called from a timer handler?"
      end
    end

    # Meant to be called from the handler. Closes the passed io, or if it's nil, closes the current io
    def close(io = nil)
      if ! io
        disposeIo @currentIoInfo if @currentIoInfo
      else
        disposeIo io
      end
    end

    # Meant to be called from the handler. Returns the current io
    def currentIo
      @currentIoInfo.readFiberIoFacade
    end

    # Meant to be called from the handler. Sets the meta info for the current io
    def setMetaInfo(metainfo)
      @currentIoInfo.metainfo = metainfo
    end

    def findIoByMetainfo(metainfo)
      @ioInfo.each_value do |info|
        if info.metainfo == metainfo
          io = info.readFiberIoFacade
          # Don't allow read calls from timer handlers. This is to prevent a complex situation.
          # See the processTimer call in eventLoopBody for more info
          io = WriteOnlyIoFacade.new(info) if @currentHandlerCallback == :timer
          return io
        end
      end
      nil
    end

    private

    # Returns :continue or :halt to the caller, specifying whether to continue the event loop or halt.
    def eventLoopBody
      readset = []
      writeset = []
      @ioInfo.each do |k,v|
        readset.push k if v.state != :connecting && ! @stopped
        @logger.debug "eventloop: IO metainfo=#{v.metainfo} added to read set" if @logger
        writeset.push k if (!v.outputBuffer.empty? || v.state == :connecting) && v.state != :listening
        @logger.debug "eventloop: IO metainfo=#{v.metainfo} added to write set" if @logger
      end
      readset.push @eventRead

      # Only exit the event loop once we've written all pending data.
      return :halt if @stopped && writeset.size == 0

      # 1. Check timers
      selectTimeout = nil
      timer = nil
      while true
        timer = @timerManager.peek
        break if ! timer
        secondsUntilExpiry = timer.secondsUntilExpiry
        if secondsUntilExpiry > 0
          selectTimeout = secondsUntilExpiry
          break
        end
        # Process timer now; it's firing time has already passed.
        processTimer(timer)
      end

      # 2. Check user events
      @userEvents.each{ |event| @handler.userEvent event }

      # 3. Call Select. Ignore exception set: apparently this is for OOB data, or terminal things.  
      selectResult = nil
      while true
        begin
          @logger.debug "eventloop: Calling select" if @logger
          selectResult = IO.select(readset, writeset, nil, selectTimeout)
          @logger.debug "eventloop: select done. result: #{selectResult.inspect}" if @logger
          break
        rescue
          # Exception occurred. Probably EINTR.
          @logger.warn "Select raised exception; will retry. Reason: #{$!}" if @logger
        end
      end

      if selectResult.nil?
        # Process timer
        @logger.debug "eventloop: processing timer" if @logger
        # Calling processTimer in withReadFiber here is not correct. What if at this point the fiber was already paused in a read, and we
        # want to process a timer? In that case we will resume the read and it will possibly finish, but we'll never 
        # call the timer handler. For this reason we must prevent read calls in timerHandlers.
        processTimer(timer)
      else
        readable, writeable = selectResult
        readable.each do |io|
          # This could be the eventRead pipe, which we use to signal shutdown.
          if io == @eventRead
            @logger.debug "Event received on the eventRead pipe." if @logger
            next
          end

          @currentIoInfo = @ioInfo[io]
          if @currentIoInfo.state == :listening
            @logger.debug "eventloop: calling handleAccept for IO metainfo=#{@currentIoInfo.metainfo}" if @logger
            # Replace the currentIoInfo with the accepted socket
            listenerMetainfo = @currentIoInfo.metainfo
            @currentIoInfo, addr, port = handleAccept(@currentIoInfo)
            withReadFiber(@currentIoInfo) do 
              @currentHandlerCallback = :serverinit
              @handler.serverInit(listenerMetainfo, addr, port)
            end
          else
            @logger.debug "eventloop: calling handleRead for IO metainfo=#{@currentIoInfo.metainfo}" if @logger
            #handleRead(@currentIoInfo)
            withReadFiber(@currentIoInfo) do 
              @currentHandlerCallback = :recv_data
              @handler.recvData @currentIoInfo.metainfo
            end
          end
        end
        writeable.each do |io|
          @currentIoInfo = @ioInfo[io]
          # Check if there is still ioInfo for this io. This can happen if this io was also ready for read, and 
          # the read had an error (for example connection failure) and the ioinfo was removed when handling the error.
          next if ! @currentIoInfo 
          if @currentIoInfo.state == :connecting
            @logger.debug "eventloop: calling finishConnection for IO metainfo=#{@currentIoInfo.metainfo}" if @logger
            finishConnection(@currentIoInfo)
          else
            @logger.debug "eventloop: calling writeOutputBuffer for IO metainfo=#{@currentIoInfo.metainfo}" if @logger
            writeOutputBuffer(@currentIoInfo)
          end
        end
      end

      :continue
    end

    def startConnection(port, addr, metainfo)
      socket = Socket.new(AF_INET, SOCK_STREAM, 0)
      addr = Socket.pack_sockaddr_in(port, addr)

      info = IOInfo.new(socket, metainfo)
      info.readFiberIoFacade.logger = @logger if @logger

      begin
        socket.connect_nonblock(addr)
        info.state = :connected
        @currentHandlerCallback = :client_init
        @handler.clientInit(ioInfo.metainfo)
      rescue Errno::EINPROGRESS
        # Connection is ongoing. 
        info.state = :connecting
      end

      info
    end

    def finishConnection(ioInfo)
      # Socket was connecting and is now writable. Check if there was a connection failure
      # This uses the getpeername method. See http://cr.yp.to/docs/connect.html
      begin
        ioInfo.io.getpeername
        ioInfo.state = :connected
        if ioInfo.connectTimer 
          @logger.debug "cancelling connect timer for IO metainfo=#{@currentIoInfo.metainfo}" if @logger
          @timerManager.cancel ioInfo.connectTimer
        end
        @currentHandlerCallback = :client_init
        @handler.clientInit(ioInfo.metainfo)
      rescue
        # Connection failed.
        @logger.debug "connection failed for IO metainfo=#{@currentIoInfo.metainfo}: #{$!}" if @logger
        @currentHandlerCallback = :connect_error
        @handler.connectError(ioInfo.metainfo, "Connection failed: #{$!}")
        disposeIo(ioInfo)
      end
    end

    def processTimer(timer)
      begin
        # Check for internal timers first.
        if timer.metainfo && timer.metainfo.is_a?(InternalTimerInfo)
          if timer.metainfo.type == :connect_timeout
            @currentHandlerCallback = :error
            @handler.error(timer.metainfo.data.metainfo, "Connection timed out")
            disposeIo(timer.metainfo.data)
          end
        else
          @currentHandlerCallback = :timer
          @handler.timerExpired(timer.metainfo)
        end
      rescue
        @logger.error "Exception in timer event handler: #{$!}" if @logger
        @logger.error $!.backtrace.join "\n" if @logger
      end
      @timerManager.next   
    end

    def disposeIo(io)
      if io.is_a?(IOInfo)
        begin
          # Flush any output
          begin
            writeOutputBuffer(io)
          rescue
          end
          io.io.close
        rescue
        end
        @ioInfo.delete io.io
      else
        begin
          io.close
        rescue
        end
        @ioInfo.delete io
      end
    end

    # Given the ioInfo for a listening socket, call accept and return the new ioInfo for the 
    # client's socket
    def handleAccept(ioInfo)
      socket, clientAddr = ioInfo.io.accept
      info = IOInfo.new(socket, ioInfo.metainfo)
      info.readFiberIoFacade.logger = @logger if @logger
      info.state = :connected
      @ioInfo[info.io] = info
      if @logger
        port, addr = Socket.unpack_sockaddr_in(clientAddr)
        @logger.debug "Accepted connection from #{addr}:#{port}" if @logger
      end
  
      [info, addr, port]
    end

    def handleRead(ioInfo)
      if ioInfo.readFiber.nil? || ! ioInfo.readFiber.alive?
        ioInfo.readFiber = Fiber.new do |ioInfo|
          @currentHandlerCallback = :recv_data
          @handler.recvData ioInfo.metainfo
        end
      end     
  
      # Allow handler to read some data.
      # This call will return either if:
      #  1. the handler needs more data but it isn't available yet,
      #  2. if it's read all the data it wanted to read for the current message it's building
      #  3. if a read error occurred.
      #
      # In case 2 the latter case the fiber will be dead. In cases 1 and 2, we should select on the socket
      # until data is ready. For case 3, the state of the ioInfo is set to error and the io should be 
      # removed. 
      ioInfo.readFiber.resume(ioInfo)
      if ioInfo.state == :error
        @currentHandlerCallback = :error
        @handler.error(ioInfo.metainfo, ioInfo.lastReadError)
        disposeIo(ioInfo)
      end
    end

    # Call the passed block in the context of the read Fiber. Basically the 
    # passed block is run as normal, but if the block performs a read from an io and that
    # read would block, the block is paused, and withReadFiber returns. The next time withReadFiber
    # is called the block will be resumed at the point of the read.
    def withReadFiber(ioInfo)
      if ioInfo.readFiber.nil? || ! ioInfo.readFiber.alive?
        ioInfo.readFiber = Fiber.new do |ioInfo|
          yield ioInfo.readFiberIoFacade
        end
      end     
  
      # Allow handler to read some data.
      # This call will return either if:
      #  1. the handler needs more data but it isn't available yet,
      #  2. if it's read all the data it wanted to read for the current message it's building
      #  3. if a read error occurred.
      #
      # In case 2 the latter case the fiber will be dead. In cases 1 and 2, we should select on the socket
      # until data is ready. For case 3, the state of the ioInfo is set to error and the io should be 
      # removed. 
      ioInfo.readFiber.resume(ioInfo)
      if ioInfo.state == :error
        @currentHandlerCallback = :error
        @handler.error(ioInfo.metainfo, ioInfo.lastReadError)
        disposeIo(ioInfo)
      end
      
    end

    def writeOutputBuffer(ioInfo)
      begin
        @logger.debug "writeOutputBuffer: flushing data" if @logger
        ioInfo.outputBuffer.flush
      rescue Errno::EWOULDBLOCK, Errno::EAGAIN, Errno::EINTR
        # Need to wait to write more.
        @logger.debug "writeOutputBuffer: write failed with retryable exception #{$!}" if @logger
      rescue
        # Write failure occurred
        @logger.debug "writeOutputBuffer: write failed with unexpected exception #{$!}" if @logger
        if ioInfo.useErrorhandler
          @currentHandlerCallback = :error
          @handler.error(ioInfo.metainfo, "Write error: #{$!}")
        else
          raise $!
        end
      end
    end

  end

end
