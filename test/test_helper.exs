# Perplexed is a library: hosts add `{Perplexed, settings}` to their own
# supervision tree. The suite starts it the same way, with no settings, so
# each test supplies what it needs through `Perplexed.Fixtures.put_config/1`.
{:ok, _supervisor} =
  Supervisor.start_link([{Perplexed, []}], strategy: :one_for_one, name: Perplexed.TestSupervisor)

ExUnit.start()
