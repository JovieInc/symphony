defmodule SymphonyElixir.TerminalFailureTest do
  use SymphonyElixir.TestSupport

  @tag :deterministic_hook
  test "direct errors and wrapped errors share the terminal classification" do
    reason = {:workspace_hook_failed, "after_create", 1, "logical path escapes root: /home/timwhite/symphony-elixir-workspaces/JOV-5492\n"}
    assert SymphonyElixir.TerminalFailure.terminal?(reason)
    assert SymphonyElixir.TerminalFailure.terminal?(%AgentRunner.Error{reason: reason})
    refute SymphonyElixir.TerminalFailure.terminal?({:workspace_hook_failed, "after_create", 1, nil})
    refute SymphonyElixir.TerminalFailure.terminal?({%AgentRunner.Error{reason: reason}, :not_a_stacktrace})
  end

  @root_error "logical path escapes root: /home/timwhite/symphony-elixir-workspaces/JOV-5492\n"

  for {name, reason, terminal?} <- [
        {"observed legacy root rejection", {:workspace_hook_failed, "after_create", 1, @root_error}, true},
        {"managed root rejection", {:workspace_hook_failed, "after_create", 1, "logical path escapes managed roots: /tmp/JOV-5492\n"}, true},
        {"hook explicit configuration failure", {:workspace_hook_failed, "after_create", 78, "invalid configuration"}, true},
        {"launcher configuration failure", {:port_exit, 78}, true},
        {"temporary launcher failure", {:port_exit, 75}, false},
        {"transient hook failure", {:workspace_hook_failed, "after_create", 1, "network temporarily unavailable"}, false},
        {"temporary hook exit", {:workspace_hook_failed, "after_create", 75, @root_error}, false},
        {"other hook phase", {:workspace_hook_failed, "before_run", 1, @root_error}, false},
        {"diagnostic embedded in unrelated output", {:workspace_hook_failed, "after_create", 1, "network log: " <> @root_error}, false},
        {"hook timeout", {:workspace_hook_timeout, "after_create", 1000}, false}
      ] do
    @tag :deterministic_hook
    test "#{name} uses the existing blocked or bounded retry state" do
      reason = unquote(Macro.escape(reason))
      terminal? = unquote(terminal?)
      id = "61e04122-9cc0-4b4f-bdc8-a9b540afe53f"
      issue = %Issue{id: id, identifier: "JOV-5492", state: "In Progress", dispatchable: true}
      ref = make_ref()
      pid = start_supervised!({Orchestrator, name: Module.concat(__MODULE__, unquote(name))})

      entry = %{
        pid: self(),
        ref: ref,
        identifier: issue.identifier,
        issue: issue,
        started_at: DateTime.utc_now(),
        workspace_path: nil,
        session_id: nil
      }

      :sys.replace_state(pid, fn state ->
        %{state | running: %{id => entry}, claimed: MapSet.new([id]), retry_attempts: %{}}
      end)

      error = %AgentRunner.Error{message: "Agent run failed", reason: reason}
      send(pid, {:DOWN, ref, :process, self(), {error, [{AgentRunner, :run, 3, []}]}})
      state = :sys.get_state(pid)
      refute Map.has_key?(state.running, id)

      if terminal? do
        assert %{identifier: "JOV-5492", workspace_path: nil, error: failure} = state.blocked[id]
        assert failure =~ "terminal agent configuration failure"
        assert MapSet.member?(state.claimed, id)
        refute Map.has_key?(state.retry_attempts, id)
        unchanged = Orchestrator.reconcile_blocked_issue_states_for_test([issue], state)
        assert Map.has_key?(unchanged.blocked, id)
        refute Map.has_key?(unchanged.retry_attempts, id)
        changed = Orchestrator.reconcile_blocked_issue_states_for_test([%{issue | state: "Backlog"}], state)
        refute Map.has_key?(changed.blocked, id)
        refute MapSet.member?(changed.claimed, id)
      else
        refute Map.has_key?(state.blocked, id)
        assert %{attempt: 1, delay_ms: 10_000} = state.retry_attempts[id]
      end
    end
  end
end
