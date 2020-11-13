# frozen_string_literal: true

module Mutant
  class Isolation
    # Isolation via the fork(2) systemcall.
    class Fork < self
      include(Adamantium::Flat, Concord.new(:world))

      READ_SIZE = 4096

      ATTRIBUTES = %i[block deadline log_pipe result_pipe world].freeze

      # Unsuccessful result as child exited nonzero
      class ChildError < Result
        include Concord::Public.new(:value, :log)
      end # ChildError

      # Unsuccessful result as fork failed
      class ForkError < Result
        include Equalizer.new
      end # ForkError

      # Pipe abstraction
      class Pipe
        include Adamantium::Flat, Anima.new(:reader, :writer)

        # Run block with pipe in binmode
        #
        # @return [undefined]
        def self.with(io)
          io.pipe(binmode: true) do |(reader, writer)|
            yield new(reader: reader, writer: writer)
          end
        end

        # Child writer end of the pipe
        #
        # @return [IO]
        def child
          reader.close
          writer
        end

        # Parent reader end of the pipe
        #
        # @return [IO]
        def parent
          writer.close
          reader
        end
      end # Pipe

      # ignore :reek:InstanceVariableAssumption
      class Parent
        include(
          Anima.new(*ATTRIBUTES),
          Procto.call
        )

        # Prevent mutation from `process.fork` to `fork` to call Kernel#fork
        undef_method :fork

        # Parent process
        #
        # @return [Result]
        def call
          @log_fragments = []

          @pid = start_child or return ForkError.new

          read_child_result
          terminate_child

          @result
        end

      private

        def start_child
          world.process.fork do
            Child.call(
              to_h.merge(
                log_pipe:    log_pipe.child,
                result_pipe: result_pipe.child
              )
            )
          end
        end

        # rubocop:disable Metrics/MethodLength
        def read_child_result
          result_fragments = []

          targets =
            {
              log_pipe.parent    => @log_fragments,
              result_pipe.parent => result_fragments
            }

          read_targets(targets)

          unless targets.empty?
            add_result(Result::Timeout.new(deadline.allowed_time))
            world.process.kill('KILL', @pid)
            return
          end

          begin
            result = world.marshal.load(result_fragments.join)
          rescue ArgumentError => exception
            add_result(Result::Exception.new(exception))
          else
            add_result(Result::Success.new(result, @log_fragments.join))
          end
        end
        # rubocop:enable Metrics/MethodLength

        def read_targets(targets)
          until targets.empty?
            status = deadline.status

            break unless status.ok?

            ready, = world.io.select(targets.keys, [], [], status.time_left)

            break unless ready

            ready.each do |fd|
              if fd.eof?
                targets.delete(fd)
              else
                targets.fetch(fd) << fd.read_nonblock(READ_SIZE)
              end
            end
          end
        end

        def terminate_child
          status = wait_child

          if status
            handle_status(status)
            return
          else
            world.process.kill('KILL', @pid)
          end

          status = wait_child

          if status
            handle_status(status)
            return
          else
            fail "Even after SIGKILL #@pid is alive, giving up"
          end
        end

        def handle_status(status)
          unless status.success? # rubocop:disable Style/GuardClause
            add_result(ChildError.new(status, @log_fragments.join))
          end
        end

        def wait_child
          process = world.process
          status = nil

          # NOTE TO SELF make it wait according to deadline before giving up.
          2.times do
            _pid, status = world.process.wait2(@pid, Process::WNOHANG)
            break if status
            world.kernel.sleep(0.1)
          end

          status
        end

        def add_result(result)
          @result = defined?(@result) ? @result.add_error(result) : result
        end
      end # Parent

      class Child
        include(
          Adamantium::Flat,
          Anima.new(*ATTRIBUTES),
          Procto.call
        )

        # Handle child process
        #
        # @return [undefined]
        def call
          world.stderr.reopen(log_pipe)
          world.stdout.reopen(log_pipe)
          result_pipe.syswrite(world.marshal.dump(block.call))
          result_pipe.close
        end

      end # Child

      private_constant(*(constants(false) - %i[ChildError ForkError]))

      # Call block in isolation
      #
      # @return [Result]
      #   execution result
      #
      # ignore :reek:NestedIterators
      #
      # rubocop:disable Metrics/MethodLength
      def call(timeout, &block)
        deadline = world.deadline(timeout)
        io = world.io
        Pipe.with(io) do |result|
          Pipe.with(io) do |log|
            Parent.call(
              block:       block,
              deadline:    deadline,
              log_pipe:    log,
              result_pipe: result,
              world:       world
            )
          end
        end
      end

      # rubocop:enable Metrics/MethodLength
    end # Fork
  end # Isolation
end # Mutant
