require "spec_helper"

shared_examples "Checkout Session API" do
  it "includes created timestamp and open status" do
    session = Stripe::Checkout::Session.create(
      line_items: [{ name: "T-shirt", quantity: 1, amount: 500, currency: "usd" }],
      success_url: "https://example.com/success"
    )
    expect(session.created).to be_a(Integer)
    expect(session.status).to eq("open")
  end

  it "returns nil payment_intent and open status on create" do
    session = Stripe::Checkout::Session.create(
      line_items: [{ name: "T-shirt", quantity: 1, amount: 500, currency: "usd" }],
      success_url: "https://example.com/success"
    )
    expect(session.payment_intent).to be_nil
    expect(session.status).to eq("open")
    expect(session.payment_status).to eq("unpaid")
  end

  it "returns nil payment_intent on retrieve for open session" do
    session = Stripe::Checkout::Session.create(
      line_items: [{ name: "T-shirt", quantity: 1, amount: 500, currency: "usd" }],
      success_url: "https://example.com/success"
    )
    retrieved = Stripe::Checkout::Session.retrieve(session.id)
    expect(retrieved.payment_intent).to be_nil
    expect(retrieved.status).to eq("open")
  end

  it "sets payment_intent and complete status after completion" do
    session = Stripe::Checkout::Session.create(
      line_items: [{ name: "T-shirt", quantity: 1, amount: 500, currency: "usd" }],
      success_url: "https://example.com/success"
    )
    pm = Stripe::PaymentMethod.create(type: "card")
    stripe_helper.complete_checkout_session(session, pm)

    completed = Stripe::Checkout::Session.retrieve(session.id)
    expect(completed.status).to eq("complete")
    expect(completed.payment_status).to eq("paid")
    expect(completed.payment_intent).not_to be_nil
    expect(completed.url).to be_nil
  end

  context "when creating a payment" do
    it "requires line_items" do
      expect do
        session = Stripe::Checkout::Session.create(
          customer: "customer_id",
          success_url: "localhost/nada",
          payment_method_types: ["card"],
        )
      end.to raise_error(Stripe::InvalidRequestError, /line_items/i)

    end
  end

  it "creates SetupIntent with setup mode" do
    session = Stripe::Checkout::Session.create(
      mode: "setup",
      payment_method_types: ["card"],
      success_url: "https://example.com/success"
    )

    expect(session.setup_intent).to_not be_empty
    setup_intent = Stripe::SetupIntent.retrieve(session.setup_intent)
    expect(setup_intent.payment_method_types).to eq(["card"])
  end

  context "when creating a subscription" do
    it "requires line_items" do
      expect do
        session = Stripe::Checkout::Session.create(
          customer: "customer_id",
          success_url: "localhost/nada",
          payment_method_types: ["card"],
          mode: "subscription",
        )
      end.to raise_error(Stripe::InvalidRequestError, /line_items/i)

    end
  end

  context "retrieve a checkout session" do
    let(:checkout_session1) { stripe_helper.create_checkout_session }

    it "can be retrieved by id" do
      checkout_session1

      checkout_session = Stripe::Checkout::Session.retrieve(checkout_session1.id)

      expect(checkout_session.id).to eq(checkout_session1.id)
    end

    it "cannot retrieve a checkout session that doesn't exist" do
      expect { Stripe::Checkout::Session.retrieve("nope") }.to raise_error { |e|
        expect(e).to be_a Stripe::InvalidRequestError
        expect(e.param).to eq("checkout_session")
        expect(e.http_status).to eq(404)
      }
    end

    it "can expand setup_intent" do
      initial_session = Stripe::Checkout::Session.create(
        mode: "setup",
        success_url: "https://example.com",
        payment_method_types: ["card"]
      )

      checkout_session = Stripe::Checkout::Session.retrieve(id: initial_session.id, expand: ["setup_intent"])

      expect(checkout_session.setup_intent).to be_a_kind_of(Stripe::SetupIntent)
    end
  end
end
