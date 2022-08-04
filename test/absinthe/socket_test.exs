defmodule AbsintheSocketTest do
  use ExUnit.Case
  doctest AbsintheSocket

  test "greets the world" do
    assert AbsintheSocket.hello() == :world
  end
end
