defmodule Opsonde.Reports do
  use Ash.Domain,
    otp_app: :opsonde

  resources do
    resource Opsonde.Reports.Report do
      define :list_reports, action: :read
      define :page_reports, action: :page
      define :get_report, action: :read, get_by: [:id]

      define :report_by_case_revision,
        action: :by_case_revision,
        args: [:case_id, :case_revision]

      define :reports_for_case, action: :for_case, args: [:case_id]

      define :create_report_record, action: :create_record
      define :generate_report, action: :generate, args: [:case_id, :expected_case_revision]
      define :period_summary, action: :period_summary, args: [:from, :to, :target_id]
    end
  end
end
