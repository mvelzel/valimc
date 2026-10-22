defmodule Valimc.AdminListFileTest do
  use ExUnit.Case, async: true
  # Vanilla's list file format (VMC-010a).
  alias Valimc.Admin.ListFile

  test "entries are written the way Gson pretty-prints them" do
    assert ListFile.pretty([]) == "[]"

    assert ListFile.pretty([
             [{"uuid", "u"}, {"name", "<A&B>"}, {"level", 4}, {"bypassesPlayerLimit", false}]
           ]) ==
             ~s([\n  {\n    "uuid": "u",\n    "name": "\\u003cA\\u0026B\\u003e",\n    "level": 4,\n    "bypassesPlayerLimit": false\n  }\n])
  end

  test "UUIDs and dates round-trip" do
    uuid = Valimc.Data.UUID.offline("Steve")
    text = ListFile.uuid_string(uuid)
    assert text =~ ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-3[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
    assert ListFile.parse_uuid(text) == {:ok, uuid}
    assert ListFile.parse_uuid("not-a-uuid") == :error

    now = System.os_time(:second)
    assert ListFile.format(now) =~ ~r/\A\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{4}\z/
    assert ListFile.parse_date(ListFile.format(now)) == {:ok, now}
    assert ListFile.parse_date("2026-10-21 01:36:21 +0200") == {:ok, 1_792_539_381}
    assert ListFile.parse_date("forever") == :error
  end

  test "files are read back and replaced atomically" do
    path = Path.join(System.tmp_dir!(), "ops-#{System.unique_integer([:positive])}.json")
    ListFile.write(path, [[{"uuid", "u"}, {"name", "n"}]])
    assert ListFile.read(path) == {:ok, [%{"uuid" => "u", "name" => "n"}]}
    refute File.exists?(path <> ".tmp")
    assert ListFile.read(path <> ".missing") == :missing
  end
end
