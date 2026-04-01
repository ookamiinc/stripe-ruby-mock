module StripeMock

  @state = 'ready'
  @instance = nil
  @original_execute_request_method = Compat.client.instance_method(Compat.method)

  def self.start
    return false if @state == 'live'
    @instance = instance = Instance.new
    Compat.client.send(:define_method, Compat.method) { |*args, **keyword_args|
      instance.mock_request(*args, **keyword_args)
    }
    @state = 'local'
  end

  def self.stop
    return unless @state == 'local'
    restore_stripe_execute_request_method
    @instance = nil
    @state = 'ready'
  end

  # Yield the given block between StripeMock.start and StripeMock.stop
  def self.mock(&block)
    begin
      self.start
      yield
    ensure
      self.stop
    end
  end

  def self.restore_stripe_execute_request_method
    Compat.client.send(:define_method, Compat.method, @original_execute_request_method)
  end

  def self.instance; @instance; end
  def self.state; @state; end

  # Prepare a payment action status for the next subscription operation.
  # This simulates 3D Secure or other authentication requirements.
  #
  # Usage:
  #   StripeMock.prepare_payment_action(:requires_action)
  #   StripeMock.prepare_payment_action(:requires_payment_method)
  def self.prepare_payment_action(status)
    if @state == 'local'
      instance
    elsif @state == 'remote'
      client
    else
      raise UnstartedStateError
    end.set_pending_payment_action(status.to_s)
  end

end
