defmodule Valimc.Physics.Swimming do
  @moduledoc "Native swimming flag transitions; a selected crawling pose does not imply swimming."
  def next(previous, sprint, water, underwater, feet_water, passenger)
      when is_boolean(previous) and is_boolean(sprint) and is_boolean(water) and
             is_boolean(underwater) and is_boolean(feet_water) and is_boolean(passenger) do
    sprint and not passenger and if(previous, do: water, else: underwater and feet_water)
  end
end
