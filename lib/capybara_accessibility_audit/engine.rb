module CapybaraAccessibilityAudit
  class Engine < ::Rails::Engine
    config.capybara_accessibility_audit = ActiveSupport::OrderedOptions.new
    config.capybara_accessibility_audit.audit_after = %i[
      visit
      click_button
      click_link
      click_link_or_button
      click_on
    ]
    # audit_enabled accepts: false (disabled), true (assert mode), or Reporter instances
    config.capybara_accessibility_audit.audit_enabled = true

    # Minitest
    initializer "capybara_accessibility_audit.minitest" do |app|
      ActiveSupport.on_load :action_dispatch_system_test_case do
        include CapybaraAccessibilityAudit::AuditSystemTestExtensions

        # Use the backwards-compatible accessor which handles conversion
        self.accessibility_audit_enabled = app.config.capybara_accessibility_audit.audit_enabled

        accessibility_audit_after app.config.capybara_accessibility_audit.audit_after
      end
    end

    # RSpec
    initializer "capybara_accessibility_audit.rspec" do |app|
      if defined?(RSpec)
        require "rspec/core"

        RSpec.configure do |config|
          config.include CapybaraAccessibilityAudit::AuditSystemTestExtensions, type: :system
          config.include CapybaraAccessibilityAudit::AuditSystemTestExtensions, type: :feature

          # Configure reporter once for the suite
          config.before(:suite) do
            reporter = CapybaraAccessibilityAudit::Reporter.from_config(
              app.config.capybara_accessibility_audit.audit_enabled
            )
            CapybaraAccessibilityAudit::Reporter.current = reporter
          end

          configure = proc do
            self.accessibility_audit_enabled = app.config.capybara_accessibility_audit.audit_enabled

            accessibility_audit_after app.config.capybara_accessibility_audit.audit_after
          end

          config.before(type: :system, &configure)
          config.before(type: :feature, &configure)

          config.after(:suite) do
            CapybaraAccessibilityAudit::Reporter.finalize_current!
          end
        end
      end
    end

    # Minitest after_run hook
    config.after_initialize do |app|
      if defined?(Minitest)
        # Configure reporter for Minitest
        reporter = CapybaraAccessibilityAudit::Reporter.from_config(
          app.config.capybara_accessibility_audit.audit_enabled
        )
        CapybaraAccessibilityAudit::Reporter.current = reporter

        Minitest.after_run do
          CapybaraAccessibilityAudit::Reporter.finalize_current!
        end
      end
    end

    rake_tasks do
      load File.expand_path("../tasks/capybara_accessibility_audit.rake", __dir__)
    end
  end
end
