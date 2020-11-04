# frozen_string_literal: true

module Mutant
  class Reporter
    class CLI
      class Printer
        # Printer for mutation config
        class Config < self

          # Report configuration
          #
          # @param [Mutant::Config] config
          #
          # @return [undefined]
          def run
            info 'Matcher:         %s', object.matcher.inspect
            info 'Integration:     %s', object.integration || 'null'
            info 'Jobs:            %s', object.jobs || 'auto'
            info 'Includes:        %s', object.includes
            info 'Requires:        %s', object.requires
          end

        end # Config
      end # Printer
    end # CLI
  end # Reporter
end # Mutant
