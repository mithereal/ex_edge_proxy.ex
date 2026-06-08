defmodule EdgeProxyTest do
  use ExUnit.Case
  doctest EdgeProxy

  test "greets the world" do
    assert EdgeProxy.hello() == :world
  end
end
