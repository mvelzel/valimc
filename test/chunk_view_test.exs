defmodule Valimc.ChunkViewTest do
  # Changes the server view distance, which every connection reads.
  use ExUnit.Case, async: false
  alias Valimc.Protocol.ClientInformation
  alias Valimc.Session.{ChunkSender, ChunkView}

  setup do
    old = Application.fetch_env!(:valimc, :view_distance)
    Application.put_env(:valimc, :view_distance, 10)
    on_exit(fn -> Application.put_env(:valimc, :view_distance, old) end)
  end

  # Vanilla's `ChunkTrackingView.isWithinDistance` with neighbours, written out.
  defp tracked?({cx, cz}, d, {x, z}),
    do: :math.pow(max(0, abs(x - cx) - 2), 2) + :math.pow(max(0, abs(z - cz) - 2), 2) < d * d

  test "the requested distance clamps between 2 and the server's, which clamps to 2..32" do
    assert Enum.map([-128, 0, 1, 2, 6, 10, 16, 127], &ChunkView.distance/1) ==
             [2, 2, 2, 2, 6, 10, 10, 10]

    for {setting, server} <- [{1, 2}, {2, 2}, {12, 12}, {40, 32}] do
      Application.put_env(:valimc, :view_distance, setting)
      assert ChunkView.server_distance() == server
      assert ChunkView.distance(127) == server
    end
  end

  test "views are vanilla's cylinder with a neighbour ring, nearest first" do
    for d <- 2..12, center <- [{0, 0}, {-3, 7}, {1_000_000, -999}] do
      {cx, cz} = center
      chunks = ChunkView.chunks({center, d})

      expected =
        for x <- (cx - d - 2)..(cx + d + 2),
            z <- (cz - d - 2)..(cz + d + 2),
            tracked?(center, d, {x, z}),
            do: {x, z}

      assert Enum.sort(chunks) == Enum.sort(expected)
      distances = Enum.map(chunks, fn {x, z} -> (x - cx) ** 2 + (z - cz) ** 2 end)
      assert distances == Enum.sort(distances)
    end

    assert length(ChunkView.chunks({{0, 0}, 2})) == 49
    assert length(ChunkView.chunks({{0, 0}, 10})) == 473
    assert ChunkView.chunks(nil) == []
  end

  test "a change enters and leaves exactly the chunks of the two views' difference" do
    cases = [
      {nil, {{0, 0}, 4}},
      {{{0, 0}, 4}, nil},
      {{{0, 0}, 4}, {{1, 0}, 4}},
      {{{0, 0}, 6}, {{0, 0}, 3}},
      {{{0, 0}, 3}, {{0, 0}, 6}},
      {{{0, 0}, 10}, {{500, 500}, 10}},
      {{{5, 5}, 7}, {{5, 5}, 7}}
    ]

    for {from, to} <- cases do
      {entering, leaving} = ChunkView.difference(from, to)
      old = MapSet.new(ChunkView.chunks(from))
      new = MapSet.new(ChunkView.chunks(to))
      assert MapSet.new(entering) == MapSet.difference(new, old)
      assert MapSet.new(leaving) == MapSet.difference(old, new)
      assert length(entering) == MapSet.size(MapSet.new(entering))
    end
  end

  test "a region intersects the view when any of its chunks is tracked" do
    view = {{0, 0}, 2}
    assert ChunkView.intersects?(view, {3, 3, 10, 10})
    refute ChunkView.intersects?(view, {4, 0, 10, 10})
    refute ChunkView.intersects?(nil, {0, 0, 1, 1})
  end

  test "the sender paces batches like vanilla's PlayerChunkSender" do
    sender = %ChunkSender{}
    assert ChunkSender.batch_size(sender) == 0
    sender = ChunkSender.tick(sender)
    assert ChunkSender.batch_size(sender) == 9
    sender = ChunkSender.sent(sender, 9)
    # One unacknowledged batch until the first acknowledgement.
    assert ChunkSender.batch_size(ChunkSender.tick(sender)) == 0

    sender = ChunkSender.acknowledged(sender, <<20.5::float-32>>)
    assert sender.quota == 1.0 and sender.max_unacknowledged == 10
    sender = ChunkSender.tick(sender)
    assert ChunkSender.batch_size(sender) == 20

    # Up to ten unacknowledged batches; a tick's quota caps at one tick's worth.
    sender =
      Enum.reduce(1..10, sender, fn _, s -> s |> ChunkSender.tick() |> ChunkSender.sent(20) end)

    assert sender.unacknowledged == 10 and ChunkSender.batch_size(ChunkSender.tick(sender)) == 0
    assert ChunkSender.tick(%ChunkSender{desired: 5.0, quota: 4.5}).quota == 5.0

    for {payload, rate} <- [
          {<<0.0::float-32>>, 0.01},
          {<<-3.0::float-32>>, 0.01},
          {<<1000.0::float-32>>, 64.0},
          {<<0x7F800000::32>>, 64.0},
          {<<0xFF800000::32>>, 0.01},
          {<<0x7FC00000::32>>, 0.01}
        ] do
      assert_in_delta ChunkSender.acknowledged(%ChunkSender{}, payload).desired, rate, 1.0e-6
    end

    # A slow client gets one chunk every fourth tick at a quarter chunk per tick.
    slow = ChunkSender.acknowledged(%ChunkSender{unacknowledged: 2}, <<0.25::float-32>>)
    slow = Enum.reduce(1..3, slow, fn _, s -> ChunkSender.tick(s) end)
    assert ChunkSender.batch_size(slow) == 0
    assert ChunkSender.batch_size(ChunkSender.tick(slow)) == 1
  end

  test "client information decodes vanilla's layout and rejects malformed settings" do
    payload = fn language, distance, tail ->
      IO.iodata_to_binary([Valimc.Protocol.Wire.string(language), <<distance::signed-8>>, tail])
    end

    settings = <<0, 1, 0x7F, 1, 0, 1, 0>>

    assert {:ok, %{language: "en_us", view_distance: 12, main_hand: 1, allows_listing: true}} =
             ClientInformation.decode(payload.("en_us", 12, settings))

    assert {:ok, %{view_distance: -3}} = ClientInformation.decode(payload.("nl_nl", -3, settings))

    for bad <- [
          payload.(String.duplicate("a", 17), 8, settings),
          payload.("en_us", 8, settings <> <<0>>),
          payload.("en_us", 8, binary_part(settings, 0, 5)),
          <<0xFF, 0xFF>>,
          <<>>
        ] do
      assert ClientInformation.decode(bad) == {:error, :invalid_client_information}
    end
  end
end
