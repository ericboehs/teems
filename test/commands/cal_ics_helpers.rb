# frozen_string_literal: true

# Graph event data and a runner for `teems cal ics` tests
module CalIcsTestHelpers
  def graph_event(uid, organizer: 'olive@example.com')
    { 'iCalUId' => uid, 'subject' => "Meeting #{uid}", 'isAllDay' => false,
      'start' => { 'dateTime' => '2026-10-21T14:00:00.0000000' },
      'end' => { 'dateTime' => '2026-10-21T15:00:00.0000000' },
      'organizer' => { 'emailAddress' => { 'name' => 'Org', 'address' => organizer } } }
  end

  # Runs `cal ics args` at a fixed time; returns stdout and stores the exit code, stderr and
  # request params. The mock checks errors before responses, so an error wins a shared path.
  def run_ics(args, events: [graph_event('a')], stubs: { 'calendarView' => { 'value' => events } }, errors: {})
    with_temp_config do
      Time.stub(:now, Time.utc(2026, 10, 20, 12)) do
        result = capture_output { |output| execute_ics(args, configured_runner(output: output), stubs, errors) }
        @stderr = result[:stderr]
        result[:stdout]
      end
    end
  end

  def execute_ics(args, runner, stubs, errors)
    client = runner.api_client
    errors.each { |path, error| client.stub_error(path, error) }
    stubs.each { |path, response| client.stub(path, response) }
    @code = Teems::Commands::Cal.new(['ics', *args], runner: runner).execute
    @params = client.calls.first[:params]
  end
end
