module Gorp
  module VERSION #:nodoc:
    MAJOR = 0
    MINOR = 18
    TINY  = 3

    STRING = [MAJOR, MINOR, TINY].join('.')
  end
end unless defined?(Gorp::VERSION)
