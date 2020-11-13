# frozen_string_literal: true

module Mutant
  class Timer
    include Concord.new(:process)

    # The now monotonic time
    #
    # @return [Float]
    def now
      process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    class Deadline
      include Anima.new(:timer, :allowed_time)

      def initialize(**arguments)
        super(**arguments)
        @start_at = timer.now
      end

      def expired?
        time_left <= 0
      end

      class Status
        include Concord::Public.new(:time_left)

        def ok?
          time_left.nil? || time_left > 0
        end
      end # Status

      def status
        Status.new(time_left)
      end

      def time_left
        allowed_time - (timer.now - @start_at)
      end

      class None < self
        include Concord.new

        STATUS = Status.new(nil)

        def time_left; end

        def expired?
          false
        end

        def status
          STATUS
        end
      end
    end # Deadline
  end # Timer
end # Mutant
