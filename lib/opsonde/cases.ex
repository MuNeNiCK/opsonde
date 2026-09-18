defmodule Opsonde.Cases do
  use Ash.Domain,
    otp_app: :opsonde

  resources do
    resource Opsonde.Cases.AuthoritySetting do
      define :list_authority_settings, action: :read
      define :current_authority_setting, action: :current
      define :create_authority_setting_revision, action: :create_revision
      define :retire_authority_setting, action: :retire, args: [:expected_revision]

      define :configure_authority_setting,
        action: :configure,
        args: [
          :expected_setting_revision,
          :authority_mode,
          :signal_automation_enabled,
          :max_elapsed_seconds,
          :max_resolver_turns,
          :max_target_requests,
          :max_effects,
          :max_related_targets,
          :max_ai_usage_units,
          :max_no_progress_turns,
          :reason
        ]
    end
  end
end
