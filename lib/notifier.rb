require "dotenv/load"
require "json"

module VCTools
  module Notifier
    def self.alert(changes)
      return if changes.empty?

      message = format_message(changes)
      puts message

      send_slack(message) if ENV["SLACK_WEBHOOK_URL"]
      send_email(changes)  if ENV["SMTP_USERNAME"]
    end

    def self.format_message(changes)
      lines = ["🔔 Bio Change Alert — #{Time.now.strftime('%Y-%m-%d %H:%M')}"]
      changes.each do |c|
        lines << ""
        lines << "@#{c[:username]} changed their #{c[:field]}:"
        lines << "  Before: #{c[:old_value] || '(empty)'}"
        lines << "  After:  #{c[:new_value] || '(empty)'}"
        lines << "  https://x.com/#{c[:username]}"
      end
      lines.join("\n")
    end

    def self.send_slack(message)
      require "faraday"
      payload = { text: message }.to_json
      Faraday.post(ENV["SLACK_WEBHOOK_URL"], payload, "Content-Type" => "application/json")
    rescue => e
      puts "[Notifier] Slack error: #{e.message}"
    end

    def self.send_email(changes)
      require "mail"

      Mail.defaults do
        delivery_method :smtp, {
          address:              ENV["SMTP_ADDRESS"] || "smtp.gmail.com",
          port:                 ENV.fetch("SMTP_PORT", 587).to_i,
          user_name:            ENV["SMTP_USERNAME"],
          password:             ENV["SMTP_PASSWORD"],
          authentication:       :plain,
          enable_starttls_auto: true
        }
      end

      body = format_message(changes)
      usernames = changes.map { |c| "@#{c[:username]}" }.uniq.join(", ")

      Mail.deliver do
        from    ENV["SMTP_USERNAME"]
        to      ENV.fetch("ALERT_TO_EMAIL", ENV["SMTP_USERNAME"])
        subject "VC Signal: Profile change detected — #{usernames}"
        body    body
      end
    rescue => e
      puts "[Notifier] Email error: #{e.message}"
    end
  end
end
