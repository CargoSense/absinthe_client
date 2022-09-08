defmodule AbsintheClientUnitTest do
  use ExUnit.Case

  doctest AbsintheClient,
    only: [
      attach: 2
    ]
end
