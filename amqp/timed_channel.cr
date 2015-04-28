module Timed
  class ChannelError < Exception; end
  class ChannelClosed < ChannelError; end
  class ChannelTimeout < ChannelError; end

  abstract class Channel(T)
    def initialize
      @senders = [] of Fiber
      @receivers = [] of Fiber
      @closed = false
    end

    def self.new
      UnbufferedChannel(T).new
    end

    def self.new(capacity)
      BufferedChannel(T).new(capacity)
    end

    def receive(timeout = 0.seconds)
      receive(timeout) { raise ChannelTimeout.new }
    end

    def receive?(timeout = 0.seconds)
      receive(timeout) { nil }
    end

    def self.select(*channels)
      loop do
        ready_channel = channels.find &.ready?
        return ready_channel if ready_channel

        channels.each &.wait
        Scheduler.reschedule
        channels.each &.unwait
      end
    end

    def close
      @closed = true
      Scheduler.enqueue @receivers
      @receivers.clear
    end

    protected def wait
      @receivers << Fiber.current
    end

    protected def unwait
      @receivers.delete Fiber.current
    end
  end

  class BufferedChannel(T) < Channel(T)
    def initialize(@capacity = 32)
      @queue = Array(T).new(@capacity)
      super()
    end

    def send(value : T)
      while full?
        raise ChannelClosed.new if @closed

        @senders << Fiber.current
        Scheduler.reschedule
      end

      raise ChannelClosed.new if @closed

      @queue << value
      Scheduler.enqueue @receivers
      @receivers.clear
    end

    def receive(timeout = 0.seconds)
      start_time = Time.now
      while empty?
        raise ChannelClosed.new if @closed

        if timeout != 0.seconds
          diff = Time.now - start_time
          if diff > timeout
            return yield
          else
            Scheduler.sleep(timeout.total_seconds)
          end
        end

        @receivers << Fiber.current
        Scheduler.reschedule
      end

      raise ChannelClosed.new if @closed

      @queue.shift.tap do
        Scheduler.enqueue @senders
        @senders.clear
      end
    end

    def full?
      @queue.length >= @capacity
    end

    def empty?
      @queue.empty?
    end

    def ready?
      @closed || @queue.any?
    end
  end

  class UnbufferedChannel(T) < Channel(T)
    def send(value : T)
      while @value
        raise ChannelClosed.new if @closed

        @senders << Fiber.current
        Scheduler.reschedule
      end

      raise ChannelClosed.new if @closed

      @value = value
      @sender = Fiber.current

      if receiver = @receivers.pop?
        receiver.resume
      else
        Scheduler.reschedule
      end
    end

    def receive(timeout = 0.seconds)
      start_time = Time.now
      while @value.nil?
        raise ChannelClosed.new if @closed

        if timeout != 0.seconds
          diff = Time.now - start_time
          if diff > timeout
            return yield
          else
            Scheduler.sleep(timeout.total_seconds)
          end
        end

        @receivers << Fiber.current
        if sender = @senders.pop?
          sender.resume
        else
          Scheduler.reschedule
        end
      end

      raise ChannelClosed.new if @closed

      @value.not_nil!.tap do
        @value = nil
        Scheduler.enqueue @sender.not_nil!
      end
    end

    def ready?
      !@value.nil?
    end
  end
end
