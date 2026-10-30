defmodule Valimc.StorageRestartAtomsTest do
  @moduledoc """
  A restarted server reads its own saves although they hold atoms its fresh VM
  does not have yet: native mobs create memory names (`job_site`,
  `meeting_point`) only while they run, so a region saved with villagers once
  refused to load after a restart (`invalid_checkpoint`). Each save here holds
  a native villager record whose memory name is renamed, byte for byte, to an
  atom this VM has never created, as a fresh VM would meet it.
  """
  use ExUnit.Case, async: true

  alias Valimc.Entity.Body
  alias Valimc.Storage.{Checkpoint, RegionLog}

  # A villager's native record and a memory under `job_site`, encoded with
  # that name replaced by a same-length atom that does not exist.
  defp unknown_atom_term do
    {:ok, villager} = Body.spawned("minecraft:villager", :natural)

    records = %{
      {:entity, <<7::128>>} => %{body: villager, memories: %{job_site: {:overworld, {1, 64, 2}}}}
    }

    name = fresh_name()
    bytes = :binary.replace(:erlang.term_to_binary(records), "job_site", name, [:global])

    # What the server refused before: `:safe` meets an atom the VM lacks.
    assert_raise ArgumentError, fn -> :erlang.binary_to_term(bytes, [:safe]) end
    {bytes, name}
  end

  defp fresh_name do
    name = "q" <> for(_ <- 1..7, into: "", do: <<Enum.random(?a..?z)>>)

    try do
      String.to_existing_atom(name)
      fresh_name()
    rescue
      ArgumentError -> name
    end
  end

  defp memory(records, name),
    do: records[{:entity, <<7::128>>}].memories[String.to_existing_atom(name)]

  test "a region or player checkpoint" do
    {term, name} = unknown_atom_term()
    body = ["VMCREG01", <<12::64>>, term]
    bytes = IO.iodata_to_binary([body, :crypto.hash(:sha256, IO.iodata_to_binary(body))])

    assert {:ok, %{seq: 12, records: records}} = Checkpoint.decode(bytes)
    assert memory(records, name) == {:overworld, {1, 64, 2}}
  end

  test "a log frame" do
    {<<131, element::binary>>, name} = unknown_atom_term()
    # A frame's ops are a list, here `[records]`: LIST_EXT of one, then NIL_EXT.
    payload = <<5::64, 1::32, 131, 108, 1::32, element::binary, 106>>
    frame = <<byte_size(payload)::32, :erlang.crc32(payload)::32, payload::binary>>

    assert {:ok, [%{lsn: 5, ops: [records]}], _, :clean} = RegionLog.decode_frames(frame)
    assert memory(records, name) == {:overworld, {1, 64, 2}}
  end

  test "a log checkpoint" do
    {term, name} = unknown_atom_term()
    body = <<"VMCCKPT1", 9::64, 1::32, term::binary>>
    bytes = body <> :crypto.hash(:sha256, body)

    assert {:ok, %{lsn: 9, state: records}} = RegionLog.decode_checkpoint(bytes)
    assert memory(records, name) == {:overworld, {1, 64, 2}}
  end

  test "damage is still refused" do
    {term, _} = unknown_atom_term()
    body = ["VMCREG01", <<12::64>>, term]
    bytes = IO.iodata_to_binary([body, :crypto.hash(:sha256, IO.iodata_to_binary(body))])
    <<head::binary-size(40), byte, tail::binary>> = bytes

    assert {:error, :invalid_checkpoint} =
             Checkpoint.decode(<<head::binary, byte + 1, tail::binary>>)
  end
end
