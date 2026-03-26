require "axe/api/context"
require "axe/api/options"
require "axe/api/results"
require "axe/configuration"

module CapybaraAccessibilityAudit
  class AxeAuditor
    class_attribute :source, instance_accessor: false, default: Axe::Configuration.instance.jslib

    def initialize(page, reporter)
      @page_proc = page.is_a?(Proc) ? page : -> { page }
      @reporter = reporter
    end

    def audit(**options)
      results = run(options)

      @reporter.report Axe::API::Results.new(results)
    end

    private

    def page
      @page_proc.call
    end

    def run(config)
      context, options = split(config)

      # Convert to JSON-compatible hashes (all symbols become strings)
      # Playwright driver can’t serialize Ruby symbols, e.g.
      #
      #   accessibility_audit_options.according_to = [
      #     :wcag2a,
      #     :wcag2aa
      #   ]
      #
      context_hash = context.to_h.as_json
      options_hash = options.to_h.as_json

      # Install axe and run in a single atomic script
      page.evaluate_async_script <<~JS, self.class.source, context_hash, options_hash
        const [ source, context, options, callback ] = arguments

        if (typeof axe === "undefined" || typeof axe.run !== "function") {
          eval(source)
        }

        axe.run(context, options).then(callback)
      JS
    end

    def split(config)
      context = Axe::API::Context.new
      options = Axe::API::Options.new

      config.each do |name, value|
        case name
        when :within, :excluding then context.public_send(name, value)
        else options.public_send(name, value)
        end
      end

      [context, options]
    end

  end
end
