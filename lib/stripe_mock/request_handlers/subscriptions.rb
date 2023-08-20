module StripeMock
  module RequestHandlers
    module Subscriptions

      def Subscriptions.included(klass)
        klass.add_handler 'get /v1/subscriptions', :retrieve_subscriptions
        klass.add_handler 'post /v1/subscriptions', :create_subscription
        klass.add_handler 'get /v1/subscriptions/(.*)', :retrieve_subscription
        klass.add_handler 'post /v1/subscriptions/(.*)', :update_subscription
        klass.add_handler 'delete /v1/subscriptions/(.*)', :cancel_subscription

        klass.add_handler 'post /v1/customers/(.*)/subscription(?:s)?', :create_customer_subscription
        klass.add_handler 'get /v1/customers/(.*)/subscription(?:s)?/(.*)', :retrieve_customer_subscription
        klass.add_handler 'get /v1/customers/(.*)/subscription(?:s)?', :retrieve_customer_subscriptions
        klass.add_handler 'post /v1/customers/(.*)subscription(?:s)?/(.*)', :update_subscription
        klass.add_handler 'delete /v1/customers/(.*)/subscription(?:s)?/(.*)', :cancel_subscription
      end

      def retrieve_customer_subscription(route, method_url, params, headers)
        stripe_account = headers && headers[:stripe_account] || Stripe.api_key
        route =~ method_url

        customer = assert_existence :customer, $1, customers[stripe_account][$1]
        subscription = get_customer_subscription(customer, $2)

        assert_existence :subscription, $2, subscription
      end

      def retrieve_customer_subscriptions(route, method_url, params, headers)
        stripe_account = headers && headers[:stripe_account] || Stripe.api_key
        route =~ method_url

        customer = assert_existence :customer, $1, customers[stripe_account][$1]
        customer[:subscriptions]
      end

      def create_customer_subscription(route, method_url, params, headers)
        stripe_account = headers && headers[:stripe_account] || Stripe.api_key
        route =~ method_url

        subscription_prices = get_subscription_prices_from_params(params)
        customer = assert_existence :customer, $1, customers[stripe_account][$1]

        if params[:source]
          new_card = get_card_by_token(params.delete(:source))
          add_card_to_object(:customer, new_card, customer)
          customer[:default_source] = new_card[:id]
        end

        subscription = Data.mock_subscription({ id: (params[:id] || new_id('su')) })
        subscription = resolve_subscription_changes(subscription, subscription_prices, customer, params)

        # Ensure customer has card to charge if price has no trial and is not free
        # Note: needs updating for subscriptions with multiple prices
        verify_card_present(customer, subscription_prices.first, subscription, params)

        if params[:coupon]
          coupon_id = params[:coupon]

          # assert_existence returns 404 error code but Stripe returns 400
          # coupon = assert_existence :coupon, coupon_id, coupons[coupon_id]

          coupon = coupons[coupon_id]

          if coupon
            add_coupon_to_object(subscription, coupon)
          else
            raise Stripe::InvalidRequestError.new("No such coupon: #{coupon_id}", 'coupon', http_status: 400)
          end
        end

        subscriptions[subscription[:id]] = subscription
        add_subscription_to_customer(customer, subscription)

        subscriptions[subscription[:id]]
      end

      def create_subscription(route, method_url, params, headers)
        stripe_account = headers && headers[:stripe_account] || Stripe.api_key
        if headers && headers[:idempotency_key]
          if subscriptions.any?
            original_subscription = subscriptions.values.find { |c| c[:idempotency_key] == headers[:idempotency_key]}
            return subscriptions[original_subscription[:id]] if original_subscription
          end
        end
        route =~ method_url

        subscription_prices = get_subscription_prices_from_params(params)

        customer = params[:customer]
        customer_id = customer.is_a?(Stripe::Customer) ? customer[:id] : customer.to_s
        customer = assert_existence :customer, customer_id, customers[stripe_account][customer_id]

        if params[:source]
          new_card = get_card_by_token(params.delete(:source))
          add_card_to_object(:customer, new_card, customer)
          customer[:default_source] = new_card[:id]
        end

        allowed_params = %w(id customer application_fee_percent coupon description items metadata price quantity source tax_percent trial_end trial_period_days current_period_start created prorate billing_cycle_anchor billing days_until_due idempotency_key enable_incomplete_payments cancel_at_period_end default_tax_rates payment_behavior pending_invoice_item_interval default_payment_method collection_method off_session proration_behavior backdate_start_date transfer_data expand automatic_tax payment_settings trial_settings)
        unknown_params = params.keys - allowed_params.map(&:to_sym)
        if unknown_params.length > 0
          raise Stripe::InvalidRequestError.new("Received unknown parameter: #{unknown_params.join}", unknown_params.first.to_s, http_status: 400)
        end

        subscription = Data.mock_subscription({ id: (params[:id] || new_id('su')) })
        subscription = resolve_subscription_changes(subscription, subscription_prices, customer, params)
        if headers[:idempotency_key]
          subscription[:idempotency_key] = headers[:idempotency_key]
        end

        # Ensure customer has card to charge if price has no trial and is not free
        # Note: needs updating for subscriptions with multiple prices
        verify_card_present(customer, subscription_prices.first, subscription, params)

        if params[:coupon]
          coupon_id = params[:coupon]

          # assert_existence returns 404 error code but Stripe returns 400
          # coupon = assert_existence :coupon, coupon_id, coupons[coupon_id]

          coupon = coupons[coupon_id]

          if coupon
            add_coupon_to_object(subscription, coupon)
          else
            raise Stripe::InvalidRequestError.new("No such coupon: #{coupon_id}", 'coupon', http_status: 400)
          end
        end

        if params[:trial_period_days]
          subscription[:status] = 'trialing'
        end

        if params[:payment_behavior] == 'default_incomplete'
          subscription[:status] = 'incomplete'
        end

        if params[:cancel_at_period_end]
          subscription[:cancel_at_period_end] = true
          subscription[:canceled_at] = Time.now.utc.to_i
        end

        if params[:transfer_data] && !params[:transfer_data].empty?
          throw Stripe::InvalidRequestError.new(missing_param_message("transfer_data[destination]")) unless params[:transfer_data][:destination]
          subscription[:transfer_data] = params[:transfer_data].dup
          subscription[:transfer_data][:amount_percent] ||= 100
        end

        payment_intent = nil
        unless subscription[:status] == 'trialing'
          intent_status = subscription[:status] == 'incomplete' ? 'requires_payment_method' : 'succeeded'
          intent = Data.mock_payment_intent({
            status: intent_status,
            amount: subscription[:price][:unit_amount],
            currency: subscription[:price][:currency]
          })
          payment_intent = intent.id
        end
        invoice = Data.mock_invoice([], { payment_intent: payment_intent })
        subscription[:latest_invoice] = invoice

        subscriptions[subscription[:id]] = subscription
        add_subscription_to_customer(customer, subscription)

        subscriptions[subscription[:id]]
      end

      def retrieve_subscription(route, method_url, params, headers)
        route =~ method_url

        assert_existence :subscription, $1, subscriptions[$1]
      end

      def retrieve_subscriptions(route, method_url, params, headers)
        # stripe_account = headers && headers[:stripe_account] || Stripe.api_key
        route =~ method_url

        subs = subscriptions.values

        case params[:status]
        when nil
          subs = subs.filter {|subscription| subscription[:status] != "canceled"}
        when "all"
          # Include all subscriptions
        else
          subs = subs.filter {|subscription| subscription[:status] == params[:status]}
        end

        Data.mock_list_object(subs, params)
      end

      def update_subscription(route, method_url, params, headers)
        stripe_account = headers && headers[:stripe_account] || Stripe.api_key
        route =~ method_url

        if params[:billing_cycle_anchor] == 'now'
          params[:billing_cycle_anchor] = Time.now.utc.to_i
        end

        subscription_id = $2 ? $2 : $1
        subscription = assert_existence :subscription, subscription_id, subscriptions[subscription_id]
        verify_active_status(subscription)

        customer_id = subscription[:customer]
        customer = assert_existence :customer, customer_id, customers[stripe_account][customer_id]

        if params[:source]
          new_card = get_card_by_token(params.delete(:source))
          add_card_to_object(:customer, new_card, customer)
          customer[:default_source] = new_card[:id]
        end

        subscription_prices = get_subscription_prices_from_params(params)

        # subscription prices are not being updated but load them for the response
        if subscription_prices.empty?
          subscription_prices = subscription[:items][:data].map { |item| item[:price] }
        end

        if params[:coupon]
          coupon_id = params[:coupon]

          # assert_existence returns 404 error code but Stripe returns 400
          # coupon = assert_existence :coupon, coupon_id, coupons[coupon_id]

          coupon = coupons[coupon_id]
          if coupon
            add_coupon_to_object(subscription, coupon)
          elsif coupon_id == ""
            subscription[:discount] = nil
          else
            raise Stripe::InvalidRequestError.new("No such coupon: #{coupon_id}", 'coupon', http_status: 400)
          end
        end

        if params[:trial_period_days]
          subscription[:status] = 'trialing'
        end

        if params[:cancel_at_period_end]
          subscription[:cancel_at_period_end] = true
          subscription[:canceled_at] = Time.now.utc.to_i
        elsif params.has_key?(:cancel_at_period_end)
          subscription[:cancel_at_period_end] = false
          subscription[:canceled_at] = nil
        end

        params[:current_period_start] = subscription[:current_period_start]
        params[:trial_end] = params[:trial_end] || subscription[:trial_end]

        price_unit_amount_was = subscription.dig(:price, :unit_amount)

        subscription = resolve_subscription_changes(subscription, subscription_prices, customer, params)

        verify_card_present(customer, subscription_prices.first, subscription, params) if price_unit_amount_was == 0 && subscription.dig(:price, :unit_amount) && subscription.dig(:price, :unit_amount) > 0

        # delete the old subscription, replace with the new subscription
        customer[:subscriptions][:data].reject! { |sub| sub[:id] == subscription[:id] }
        customer[:subscriptions][:data] << subscription

        subscription
      end

      def cancel_subscription(route, method_url, params, headers)
        stripe_account = headers && headers[:stripe_account] || Stripe.api_key
        route =~ method_url

        subscription_id = $2 ? $2 : $1
        subscription = assert_existence :subscription, subscription_id, subscriptions[subscription_id]

        customer_id = subscription[:customer]
        customer = assert_existence :customer, customer_id, customers[stripe_account][customer_id]

        cancel_params = { canceled_at: Time.now.utc.to_i }
        cancelled_at_period_end = (params[:at_period_end] == true)
        if cancelled_at_period_end
          cancel_params[:cancel_at_period_end] = true
        else
          cancel_params[:status] = 'canceled'
          cancel_params[:cancel_at_period_end] = false
          cancel_params[:ended_at] = Time.now.utc.to_i
        end

        subscription.merge!(cancel_params)

        unless cancelled_at_period_end
          delete_subscription_from_customer customer, subscription
        end

        subscription
      end

      private

      def get_subscription_prices_from_params(params)
        price_ids = if params[:price]
                     [params[:price].to_s]
                   elsif params[:items]
                     items = params[:items]
                     items = items.values if items.respond_to?(:values)
                     items.map { |item| item[:price] ? item[:price] : item[:price] }
                   else
                     []
                   end
        price_ids.compact!
        price_ids.each do |price_id|
          assert_existence :price, price_id, prices[price_id]
        rescue Stripe::InvalidRequestError
          assert_existence :price, price_id, prices[price_id]
        end
        price_ids.map { |price_id| prices[price_id] || prices[price_id]}
      end

      # Ensure customer has card to charge unless one of the following criterias is met:
      # 1) is in trial
      # 2) is free
      # 3) has billing set to send invoice
      def verify_card_present(customer, price, subscription, params={})
        return if customer[:default_source]
        return if customer[:invoice_settings][:default_payment_method]
        return if customer[:trial_end]
        return if params[:trial_end]
        return if params[:payment_behavior] == 'default_incomplete'
        return if subscription[:default_payment_method]

        price_trial_period_days = price[:trial_period_days] || 0
        price_has_trial = price_trial_period_days != 0 || price[:unit_amount] == 0 || price[:trial_end]
        return if price && price_has_trial

        return if subscription && subscription[:trial_end] && subscription[:trial_end] != 'now'

        if subscription[:items]
          trial = subscription[:items][:data].none? do |item|
            price = item[:price]
            (price[:trial_period_days].nil? || price[:trial_period_days] == 0) &&
              (price[:trial_end].nil? || price[:trial_end] == 'now')
          end
          return if trial
        end

        return if params[:billing] == 'send_invoice'

        raise Stripe::InvalidRequestError.new('This customer has no attached payment source', nil, http_status: 400)
      end

      def verify_active_status(subscription)
        id, status = subscription.values_at(:id, :status)

        if status == 'canceled'
          message = "No such subscription: #{id}"
          raise Stripe::InvalidRequestError.new(message, 'subscription', http_status: 404)
        end
      end
    end
  end
end
