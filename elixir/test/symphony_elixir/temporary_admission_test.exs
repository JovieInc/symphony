defmodule SymphonyElixir.TemporaryAdmissionTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.TemporaryAdmission

  @inventory ~s(SYMPHONY_LAUNCHER_FAILURE schema=symphony-launcher-failure/v1 class=pr-inventory-unknown retryable=true reason="open_pr_inventory_unknown JOV-5995")

  test "only exact machine admission receipts are accepted" do
    assert {:ok, %{class: :pr_inventory_unknown, identifier: "JOV-5995"}} = TemporaryAdmission.parse_line(@inventory)

    for reason <- ["dispatch_gate_closed", "dispatch_admission_unavailable"] do
      line = ~s(SYMPHONY_LAUNCHER_FAILURE schema=symphony-launcher-failure/v1 class=pickup-refused retryable=true reason="#{reason} owns JOV-5995")
      assert {:ok, %{class: :dispatch_admission, reason: ^reason}} = TemporaryAdmission.parse_line(line)
    end

    for line <- [
          "",
          "prefix " <> @inventory,
          @inventory <> " extra=true",
          String.replace(@inventory, "retryable=true", "retryable=false"),
          String.replace(@inventory, "v1", "v2"),
          String.replace(@inventory, "JOV-5995", "JOV-0"),
          String.replace(@inventory, "open_pr_inventory_unknown", "founder_cancelled")
        ] do
      assert :error = TemporaryAdmission.parse_line(line)
    end
  end

  test "hook classification requires one exact receipt and before_run exit 75" do
    failure = {:workspace_hook_failed, "before_run", 75, "diagnostic\n" <> @inventory <> "\n"}
    assert {:ok, %{class: :pr_inventory_unknown}} = TemporaryAdmission.from_hook(failure)

    for reason <- [
          nil,
          {:workspace_hook_failed, "after_create", 75, @inventory},
          {:workspace_hook_failed, "before_run", 78, @inventory},
          {:workspace_hook_failed, "before_run", 75, "unknown error"},
          {:workspace_hook_failed, "before_run", 75, @inventory <> "\n" <> @inventory},
          {:workspace_hook_failed, "before_run", 75, @inventory <> "\nCAPACITY_UNAVAILABLE"},
          {:workspace_hook_failed, "before_run", 75, "prefix " <> @inventory}
        ] do
      assert :error = TemporaryAdmission.from_hook(reason)
    end
  end
end
