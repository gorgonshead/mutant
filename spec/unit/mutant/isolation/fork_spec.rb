# frozen_string_literal: true

# The fork isolation is all about managing a series of systemcalls with proper error handling
#
# So creating a unit spec for this is challenging. Especially under mutation testing.
# Hence we even have to implement our own message expectation mechanism, as rspec build in
# expectations are not able to correctly specify a sequence of expectations where a specific
# message is send twice.
#
# Also our replacement for rspec-expectations used here allows easier deduplication.
RSpec.describe Mutant::Isolation::Fork do
  let(:block_return)      { instance_double(Object, :block_return)      }
  let(:block_return_blob) { instance_double(String, :block_return_blob) }
  let(:isolated_block)    { -> { block_return }                         }
  let(:log_fragment)      { 'log message'                               }
  let(:log_reader)        { instance_double(IO, :log_reader)            }
  let(:log_writer)        { instance_double(IO, :log_writer)            }
  let(:pid)               { class_double(Integer)                       }
  let(:result_fragment)   { 'result body'                               }
  let(:result_reader)     { instance_double(IO, :result_reader)         }
  let(:result_writer)     { instance_double(IO, :result_writer)         }
  let(:timeout)           { nil                                         }

  let(:status_success) do
    instance_double(Process::Status, success?: true)
  end

  let(:world) { fake_world }

  let(:fork_success) do
    {
      receiver: world.process,
      selector: :fork,
      reaction: {
        yields: [],
        return: pid
      }
    }
  end

  let(:child_wait) do
    {
      receiver:  world.process,
      selector:  :wait2,
      arguments: [pid, Process::WNOHANG],
      reaction:  {
        return: [pid, status_success]
      }
    }
  end

  def close(descriptor)
    {
      receiver: descriptor,
      selector: :close
    }
  end

  let(:load_success) do
    {
      receiver:  world.marshal,
      selector:  :load,
      arguments: [result_fragment],
      reaction:  {
        return: block_return
      }
    }
  end

  let(:read_fragments) do
    [
      {
        receiver:  world.io,
        selector:  :select,
        arguments: [[log_reader, result_reader], [], [], nil],
        reaction:  { return: [[log_reader, result_reader], [], []] }
      },
      {
        receiver: log_reader,
        selector: :eof?,
        reaction: { return: false }
      },
      {
        receiver:  log_reader,
        selector:  :read_nonblock,
        arguments: [4096],
        reaction:  { return: log_fragment }
      },
      {
        receiver: result_reader,
        selector: :eof?,
        reaction: { return: false }
      },
      {
        receiver:  result_reader,
        selector:  :read_nonblock,
        arguments: [4096],
        reaction:  { return: result_fragment }
      },
      {
        receiver:  world.io,
        selector:  :select,
        arguments: [[log_reader, result_reader], [], [], nil],
        reaction:  { return: [[log_reader, result_reader], [], []] }
      },
      {
        receiver: log_reader,
        selector: :eof?,
        reaction: { return: true }
      },
      {
        receiver: result_reader,
        selector: :eof?,
        reaction: { return: true }
      }
    ]
  end

  let(:killfork) do
    [
      {
        receiver: log_reader,
        selector: :close
      },
      {
        receiver: result_reader,
        selector: :close
      },
      {
        receiver:  world.stderr,
        selector:  :reopen,
        arguments: [log_writer]
      },
      {
        receiver:  world.stdout,
        selector:  :reopen,
        arguments: [log_writer]
      },
      {
        receiver:  world.marshal,
        selector:  :dump,
        arguments: [block_return],
        reaction:  { return: block_return_blob }
      },
      {
        receiver:  result_writer,
        selector:  :syswrite,
        arguments: [block_return_blob]
      },
      close(result_writer),
      close(log_writer)
    ]
  end

  describe '#call' do
    subject { described_class.new(world) }

    def apply
      subject.call(timeout, &isolated_block)
    end

    let(:prefork_expectations) do
      [
        {
          receiver:  world.io,
          selector:  :pipe,
          arguments: [binmode: true],
          reaction:  {
            yields: [[result_reader, result_writer]]
          }
        },
        {
          receiver:  world.io,
          selector:  :pipe,
          arguments: [binmode: true],
          reaction:  {
            yields: [[log_reader, log_writer]]
          }
        }
      ]
    end

    context 'happy paths without configured timeouts' do
      let(:expectations) do
        [
          *prefork_expectations,
          fork_success,
          *killfork,
          close(result_writer),
          *read_fragments,
          load_success,
          child_wait
        ].map { |attributes| XSpec::MessageExpectation.parse(**attributes) }
      end

      specify do
        XSpec::ExpectationVerifier.verify(self, expectations) do
          expect(apply).to eql(Mutant::Isolation::Result::Success.new(block_return, log_fragment))
        end
      end
    end

    def timer(now)
      {
        receiver: world.timer,
        selector: :now,
        reaction: { return: now }
      }
    end

    context 'with configured timeouts' do
      let(:timeout) { 4.0 }

      let(:prefork_expectations) do
        [timer(0.0), *super()]
      end

      context 'reads within timeout' do
        let(:read_fragments) do
          [
            timer(1.0),
            {
              receiver:  world.io,
              selector:  :select,
              arguments: [[log_reader, result_reader], [], [], 3.0],
              reaction:  { return: [[log_reader, result_reader], [], []] }
            },
            {
              receiver: log_reader,
              selector: :eof?,
              reaction: { return: false }
            },
            {
              receiver:  log_reader,
              selector:  :read_nonblock,
              arguments: [4096],
              reaction:  { return: log_fragment }
            },
            {
              receiver: result_reader,
              selector: :eof?,
              reaction: { return: false }
            },
            {
              receiver:  result_reader,
              selector:  :read_nonblock,
              arguments: [4096],
              reaction:  { return: result_fragment }
            },
            timer(2.0),
            {
              receiver:  world.io,
              selector:  :select,
              arguments: [[log_reader, result_reader], [], [], 2.0],
              reaction:  { return: [[log_reader, result_reader], [], []] }
            },
            {
              receiver: log_reader,
              selector: :eof?,
              reaction: { return: true }
            },
            {
              receiver: result_reader,
              selector: :eof?,
              reaction: { return: true }
            }
          ]
        end

        let(:expectations) do
          [
            *prefork_expectations,
            fork_success,
            *killfork,
            close(result_writer),
            *read_fragments,
            load_success,
            child_wait
          ].map { |attributes| XSpec::MessageExpectation.parse(**attributes) }
        end

        specify do
          XSpec::ExpectationVerifier.verify(self, expectations) do
            expect(apply).to eql(Mutant::Isolation::Result::Success.new(block_return, log_fragment))
          end
        end
      end

      context 'timeout from select' do
        let(:read_fragments) do
          [
            timer(1.0),
            {
              receiver:  world.io,
              selector:  :select,
              arguments: [[log_reader, result_reader], [], [], 3.0],
              reaction:  { return: nil }
            }
          ]
        end

        let(:expectations) do
          [
            *prefork_expectations,
            fork_success,
            *killfork,
            close(result_writer),
            *read_fragments,
            {
              receiver: world.process,
              selector: :kill,
              arguments: ['KILL', pid]
            },
            child_wait
          ].map { |attributes| XSpec::MessageExpectation.parse(**attributes) }
        end

        specify do
          XSpec::ExpectationVerifier.verify(self, expectations) do
            expect(apply).to eql(Mutant::Isolation::Result::Timeout.new(timeout))
          end
        end
      end

      context 'timeout outside select' do
        let(:read_fragments) do
          [
            timer(5.0)
          ]
        end

        let(:expectations) do
          [
            *prefork_expectations,
            fork_success,
            *killfork,
            close(result_writer),
            *read_fragments,
            {
              receiver: world.process,
              selector: :kill,
              arguments: ['KILL', pid]
            },
            child_wait
          ].map { |attributes| XSpec::MessageExpectation.parse(**attributes) }
        end

        specify do
          XSpec::ExpectationVerifier.verify(self, expectations) do
            expect(apply).to eql(Mutant::Isolation::Result::Timeout.new(timeout))
          end
        end
      end
    end

    context 'when expected exception was raised when loading result' do
      let(:exception) { ArgumentError.new }

      let(:expectations) do
        [
          *prefork_expectations,
          fork_success,
          *killfork,
          close(result_writer),
          *read_fragments,
          {
            receiver:  world.marshal,
            selector:  :load,
            arguments: [result_fragment],
            reaction:  {
              exception: exception
            }
          },
          child_wait
        ].map { |attributes| XSpec::MessageExpectation.parse(**attributes) }
      end

      specify do
        XSpec::ExpectationVerifier.verify(self, expectations) do
          expect(apply).to eql(Mutant::Isolation::Result::Exception.new(exception))
        end
      end
    end

    context 'when fork fails' do
      let(:result_class) { described_class::ForkError }

      let(:expectations) do
        [
          *prefork_expectations,
          {
            receiver: world.process,
            selector: :fork,
            reaction: {
              return: nil
            }
          }
        ].map { |attributes| XSpec::MessageExpectation.parse(**attributes) }
      end

      specify do
        XSpec::ExpectationVerifier.verify(self, expectations) do
          expect(apply).to eql(result_class.new)
        end
      end
    end

    context 'when child exits nonzero' do
      let(:status_error) do
        instance_double(Process::Status, success?: false)
      end

      let(:expected_result) do
        Mutant::Isolation::Result::ErrorChain.new(
          described_class::ChildError.new(status_error, log_fragment),
          Mutant::Isolation::Result::Success.new(block_return, log_fragment)
        )
      end

      let(:expectations) do
        [
          *prefork_expectations,
          fork_success,
          *killfork,
          close(result_writer),
          *read_fragments,
          load_success,
          {
            receiver:  world.process,
            selector:  :wait2,
            arguments: [pid, Process::WNOHANG],
            reaction:  {
              return: [pid, status_error]
            }
          }
        ].map { |attributes| XSpec::MessageExpectation.parse(**attributes) }
      end

      specify do
        XSpec::ExpectationVerifier.verify(self, expectations) do
          expect(apply).to eql(expected_result)
        end
      end
    end
  end
end
