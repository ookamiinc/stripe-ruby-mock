module StripeMock
  module RequestHandlers
    module Subscriptions

      def Subscriptions.included(klass)
        klass.add_handler 'get /v1/subscriptions', :retrieve_subscriptions
        klass.add_handler 'post /v1/subscriptions', :create_subscription
        klass.add_handler 'get /v1/subscriptions/((?!search).*)', :retrieve_subscription
        klass.add_handler 'post /v1/subscriptions/(.*)', :update_subscription
        klass.add_handler 'get /v1/subscriptions/search', :search_subscriptions
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

        subscription_plans = get_subscription_plans_from_params(params)
        customer = assert_existence :customer, $1, customers[stripe_account][$1]

        if params[:source]
          new_card = get_card_by_token(params.delete(:source))
          add_card_to_object(:customer, new_card, customer)
          customer[:default_source] = new_card[:id]
        end

        subscription = Data.mock_subscription({ id: (params[:id] || new_id('su')), description: params[:description] })
        subscription = resolve_subscription_changes(subscription, subscription_plans, customer, params)

        # Ensure customer has card to charge if plan has no trial and is not free
        # Note: needs updating for subscriptions with multiple plans
        verify_card_present(customer, subscription_plans.first, subscription, params)

        if params[:coupon]
          coupon_id = params[:coupon]

          # assert_existence returns 404 error code but Stripe returns 400
          # coupon = assert_existence :coupon, coupon_id, coupons[coupon_id]

          coupon = coupons[coupon_id]

          if coupon
            add_coupon_to_object(subscription, coupon)
          else
            raise Stripe::InvalidRequestError.new("No such coupon: '#{coupon_id}'", 'coupon', http_status: 400)
          end
        end

        if params[:promotion_code]
          promotion_code_id = params[:promotion_code]

          promotion_code = promotion_codes[promotion_code_id]

          unless promotion_code
            raise Stripe::InvalidRequestError.new("No such promotion code: '#{promotion_code_id}'", 'promotion_code', http_status: 400)
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

        subscription_plans = get_subscription_plans_from_params(params)

        customer = params[:customer]
        customer_id = customer.is_a?(Stripe::Customer) ? customer[:id] : customer.to_s
        customer = assert_existence :customer, customer_id, customers[stripe_account][customer_id]

        if params[:source]
          new_card = get_card_by_token(params.delete(:source))
          add_card_to_object(:customer, new_card, customer)
          customer[:default_source] = new_card[:id]
        end

        allowed_params = %w(id customer application_fee_percent coupon description items metadata plan price quantity source tax_percent trial_end trial_period_days current_period_start created prorate billing_cycle_anchor billing days_until_due idempotency_key enable_incomplete_payments cancel_at_period_end default_tax_rates payment_behavior pending_invoice_item_interval default_payment_method collection_method off_session trial_from_plan proration_behavior backdate_start_date transfer_data expand automatic_tax payment_settings trial_settings promotion_code)
        unknown_params = params.keys - allowed_params.map(&:to_sym)
        if unknown_params.length > 0
          raise Stripe::InvalidRequestError.new("Received unknown parameter: #{unknown_params.join}", unknown_params.first.to_s, http_status: 400)
        end

        subscription = Data.mock_subscription({ id: (params[:id] || new_id('su')), description: params[:description] })
        subscription = resolve_subscription_changes(subscription, subscription_plans, customer, params)
        if headers[:idempotency_key]
          subscription[:idempotency_key] = headers[:idempotency_key]
        end

        # Ensure customer has card to charge if plan has no trial and is not free
        # Note: needs updating for subscriptions with multiple plans
        verify_card_present(customer, subscription_plans.first, subscription, params)

        if params[:coupon] && params[:promotion_code]
          raise Stripe::InvalidRequestError.new("You may only specify one of these parameters: coupon, promotion_code", "coupon", http_status: 400)
        end

        if params[:coupon]
          coupon_id = params[:coupon]

          # assert_existence returns 404 error code but Stripe returns 400
          # coupon = assert_existence :coupon, coupon_id, coupons[coupon_id]

          coupon = coupons[coupon_id]

          if coupon
            add_coupon_to_object(subscription, coupon)
          else
            raise Stripe::InvalidRequestError.new("No such coupon: '#{coupon_id}'", 'coupon', http_status: 400)
          end
        end

        if params[:promotion_code]
          promotion_code_id = params[:promotion_code]

          promotion_code = promotion_codes[promotion_code_id]

          unless promotion_code
            raise Stripe::InvalidRequestError.new("No such promotion code: '#{promotion_code_id}'", 'promotion_code', http_status: 400)
          end
        end

        if params[:trial_period_days]
          subscription[:status] = 'trialing'
          subscription[:trial_end] ||= Time.now.utc.to_i + params[:trial_period_days] * 86400
          subscription[:trial_start] ||= Time.now.utc.to_i
        end

        if params[:payment_behavior] == 'default_incomplete'
          subscription[:status] = 'incomplete'
        end

        if params[:cancel_at_period_end]
          subscription[:cancel_at_period_end] = true
          subscription[:canceled_at] = Time.now.utc.to_i
        end

        if params[:transfer_data] && !params[:transfer_data].empty?
          raise Stripe::InvalidRequestError.new(missing_param_message("transfer_data[destination]")) unless params[:transfer_data][:destination]
          subscription[:transfer_data] = params[:transfer_data].dup
          subscription[:transfer_data][:amount_percent] ||= 100
        end

        # Check for pending payment action (3DS) or queued card error
        # This simulates real Stripe's allow_incomplete default behavior
        pi_status_override = nil
        if @pending_payment_action
          subscription[:status] = 'incomplete'
          pi_status_override = @pending_payment_action
          @pending_payment_action = nil
        elsif @error_queue.error_for_handler_name(:new_subscription)
          @error_queue.dequeue
          subscription[:status] = 'incomplete'
          pi_status_override = 'requires_payment_method'
        end

        subscriptions[subscription[:id]] = subscription
        add_subscription_to_customer(customer, subscription, pi_status_override: pi_status_override)

        if params[:expand]
          result = subscription.clone
          generate_subscription_invoice_if_needed(
            result, params[:expand], pi_status_override: pi_status_override
          )
          expand_subscription_fields(result, params[:expand], stripe_account)
          return result
        end

        subscriptions[subscription[:id]]
      end

      def retrieve_subscription(route, method_url, params, headers)
        stripe_account = headers && headers[:stripe_account] || Stripe.api_key
        route =~ method_url

        subscription = assert_existence :subscription, $1, subscriptions[$1]
        subscription = subscription.clone

        if params[:expand]
          expand_subscription_fields(subscription, params[:expand], stripe_account)
        end

        subscription
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
        if params[:current_period_end]
          subs = filter_by_timestamp(subs, field: :current_period_end, value: params[:current_period_end])
        end
        if params[:current_period_start]
          subs = filter_by_timestamp(subs, field: :current_period_start, value: params[:current_period_start])
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

        subscription_plans = get_subscription_plans_from_params(params)

        # subscription plans are not being updated but load them for the response
        if subscription_plans.empty?
          subscription_plans = subscription[:items][:data].map { |item| item[:plan] || item[:price] }
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
            raise Stripe::InvalidRequestError.new("No such coupon: '#{coupon_id}'", 'coupon', http_status: 400)
          end
        end

        if params[:promotion_code]
          promotion_code_id = params[:promotion_code]

          promotion_code = promotion_codes[promotion_code_id]

          if promotion_code
            # You can't apply a promotion code with amount restrictions on the Customer object or on a subscription
            # update API call
            if promotion_code[:restrictions][:minimum_amount]
              raise Stripe::InvalidRequestError.new(
                "This promotion code cannot be redeemed on a subcription update because it uses the `minimum_amount` restriction.",
                "promotion_code",
                http_status: 400
              )
            end
          else
            raise Stripe::InvalidRequestError.new("No such promotion code: '#{promotion_code_id}'", 'promotion_code', http_status: 400)
          end
        end

        if params[:pause_collection]
          subscription[:pause_collection] = { resumes_at: nil }.merge(params[:pause_collection])
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

        params[:current_period_start] = params[:billing_cycle_anchor] || subscription[:current_period_start]
        params[:trial_end] = params[:trial_end] || subscription[:trial_end]

        plan_amount_was = subscription.dig(:plan, :amount) || subscription.dig(:plan, :unit_amount) || subscription.dig(:items, :data, 0, :price, :unit_amount)

        subscription = resolve_subscription_changes(subscription, subscription_plans, customer, params)

        # Fix current_period_end for billing_cycle_anchor updates
        # resolve_subscription_changes sets end = anchor, but for updates
        # it should be anchor + interval
        if params[:billing_cycle_anchor]
          plan = subscription_plans.first
          subscription[:current_period_start] = params[:billing_cycle_anchor]
          subscription[:current_period_end] = get_ending_time(params[:billing_cycle_anchor], plan)
        end

        current_amount = subscription.dig(:plan, :amount) || subscription.dig(:plan, :unit_amount) || subscription.dig(:items, :data, 0, :price, :unit_amount)
        verify_card_present(customer, subscription_plans.first, subscription, params) if plan_amount_was == 0 && current_amount && current_amount > 0

        # delete the old subscription, replace with the new subscription
        customer[:subscriptions][:data].reject! { |sub| sub[:id] == subscription[:id] }
        customer[:subscriptions][:data] << subscription

        if params[:default_payment_method] && !payment_methods[params[:default_payment_method]]
          pm_id = params[:default_payment_method]
          raise Stripe::InvalidRequestError.new(
            "No such PaymentMethod: '#{pm_id}'; It's possible this PaymentMethod exists on one of your connected accounts, in which case you should retry this request on that connected account. Learn more at https://stripe.com/docs/connect/authentication",
            'payment_method', http_status: 404
          )
        end

        # Check for pending payment action (3DS) or queued card error
        # This simulates incomplete subscriptions from authentication or decline
        card_error = @error_queue.error_for_handler_name(:subscription_update)
        pi_status_override = nil
        if @pending_payment_action
          subscription[:status] = 'incomplete'
          subscriptions[subscription[:id]][:status] = 'incomplete'
          pi_status_override = @pending_payment_action
          @pending_payment_action = nil
        elsif card_error
          @error_queue.dequeue
          subscription[:status] = 'incomplete'
          subscriptions[subscription[:id]][:status] = 'incomplete'
          pi_status_override = 'requires_payment_method'
        end

        if params[:expand]
          subscription = subscription.clone
          force_new_invoice = params.key?(:billing_cycle_anchor) || !pi_status_override.nil?
          generate_subscription_invoice_if_needed(
            subscription, params[:expand],
            force_new: force_new_invoice, pi_status_override: pi_status_override
          )
          expand_subscription_fields(subscription, params[:expand], stripe_account)
        end

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

      SEARCH_FIELDS = ["status"].freeze
      def search_subscriptions(route, method_url, params, headers)
        require_param(:query) unless params[:query]

        results = search_results(subscriptions.values, params[:query], fields: SEARCH_FIELDS, resource_name: "subscriptions")
        Data.mock_list_object(results, params)
      end

      private

      def get_subscription_plans_from_params(params)
        plan_ids = if params[:plan]
                     [params[:plan].to_s]
                   elsif params[:price]
                     [params[:price].to_s]
                   elsif params[:items]
                     items = params[:items]
                     items = items.values if items.respond_to?(:values)
                     items.map { |item| item[:plan] ? item[:plan] : item[:price] }
                   else
                     []
                   end
        plan_ids.compact!
        plan_ids.each do |plan_id|
          assert_existence :plan, plan_id, plans[plan_id]
        rescue Stripe::InvalidRequestError
          assert_existence :price, plan_id, prices[plan_id]
        end
        plan_ids.map { |plan_id| plans[plan_id] || prices[plan_id]}
      end

      # Ensure customer has card to charge unless one of the following criterias is met:
      # 1) is in trial
      # 2) is free
      # 3) has billing set to send invoice
      def verify_card_present(customer, plan, subscription, params={})
        return if customer[:default_source]
        return if customer[:invoice_settings][:default_payment_method]
        return if customer[:trial_end]
        return if params[:trial_end]
        return if params[:payment_behavior] == 'default_incomplete'
        return if subscription[:default_payment_method]

        plan_trial_period_days = plan[:trial_period_days] || 0
        plan_amount = plan[:amount] || plan[:unit_amount] || 0
        plan_has_trial = plan_trial_period_days != 0 || plan_amount == 0 || plan[:trial_end]
        return if plan && plan_has_trial

        return if subscription && subscription[:trial_end] && subscription[:trial_end] != 'now'

        if subscription[:items]
          trial = subscription[:items][:data].none? do |item|
            p = item[:plan] || item[:price]
            (p[:trial_period_days].nil? || p[:trial_period_days] == 0) &&
              (p[:trial_end].nil? || p[:trial_end] == 'now')
          end
          return if trial
        end

        return if params[:billing] == 'send_invoice'
        return if params[:collection_method] == 'send_invoice'

        raise Stripe::InvalidRequestError.new('This customer has no attached payment source', nil, http_status: 400)
      end

      def generate_subscription_invoice_if_needed(subscription, expand_list, force_new: false, pi_status_override: nil)
        needs_invoice = expand_list.any? { |s| s.start_with?('latest_invoice') }
        return unless needs_invoice

        # If latest_invoice is already stored, no need to generate (unless forced)
        unless force_new
          invoice_id = subscription[:latest_invoice]
          return if invoice_id.is_a?(Hash)
          return if invoice_id.is_a?(String) && invoices[invoice_id]
        end

        # Generate invoice for expansion (e.g., trialing subs without stored invoice)
        plan_or_price = subscription[:plan] || subscription.dig(:items, :data, 0, :price)
        return unless plan_or_price

        pi_value = nil
        unless subscription[:status] == 'trialing'
          pi_status = if pi_status_override
                        pi_status_override
                      elsif subscription[:status] == 'incomplete'
                        'requires_payment_method'
                      else
                        'succeeded'
                      end
          intent = Data.mock_payment_intent({
            id: new_id('pi'),
            status: pi_status,
            amount: plan_or_price[:amount] || plan_or_price[:unit_amount],
            currency: plan_or_price[:currency]
          })
          payment_intents[intent[:id]] = intent
          expand_pi = expand_list.any? { |s| s.include?('latest_invoice.payment_intent') }
          pi_value = expand_pi ? intent : intent[:id]
        end

        is_incomplete = subscription[:status] == 'incomplete'
        is_send_invoice = subscription[:collection_method] == 'send_invoice'
        invoice_status = if is_send_invoice
                           'draft'
                         elsif is_incomplete
                           'open'
                         else
                           'paid'
                         end

        invoice = Data.mock_invoice([], {
          id: new_id('in'),
          payment_intent: pi_value,
          subscription: subscription[:id],
          customer: subscription[:customer],
          status: invoice_status,
          paid: (!is_incomplete && !is_send_invoice)
        })
        invoices[invoice[:id]] = invoice
        subscription[:latest_invoice] = invoice
      end

      def expand_subscription_fields(subscription, expand_list, stripe_account)
        expand_list.each do |field|
          case field
          when 'customer'
            customer_id = subscription[:customer]
            customer = customers[stripe_account][customer_id] if customer_id
            subscription[:customer] = customer if customer
          when 'default_payment_method'
            pm_id = subscription[:default_payment_method]
            pm = payment_methods[pm_id] if pm_id
            subscription[:default_payment_method] = pm if pm
          when 'latest_invoice'
            invoice_id = subscription[:latest_invoice]
            if invoice_id.is_a?(String)
              invoice = invoices[invoice_id]
              subscription[:latest_invoice] = invoice.clone if invoice
            end
          when /^latest_invoice\.payment_intent/
            expand_pm = field.include?('payment_method')
            invoice_id = subscription[:latest_invoice]
            if invoice_id.is_a?(String)
              invoice = invoices[invoice_id]
              if invoice
                invoice = invoice.clone
                pi_id = invoice[:payment_intent]
                if pi_id.is_a?(String)
                  pi = payment_intents[pi_id].clone
                  expand_payment_method(pi) if expand_pm
                  invoice[:payment_intent] = pi
                end
                subscription[:latest_invoice] = invoice
              end
            elsif invoice_id.is_a?(Hash)
              pi_id = invoice_id[:payment_intent]
              if pi_id.is_a?(String)
                pi = payment_intents[pi_id].clone
                expand_payment_method(pi) if expand_pm
                invoice_id[:payment_intent] = pi
              end
            end
          when 'customer.default_source'
            customer_obj = subscription[:customer]
            customer_obj = customers[stripe_account][customer_obj] if customer_obj.is_a?(String)
            if customer_obj
              subscription[:customer] = customer_obj unless subscription[:customer].is_a?(Hash)
              source_id = customer_obj[:default_source]
              if source_id.is_a?(String)
                source = customer_obj.dig(:sources, :data)&.find { |s| s[:id] == source_id }
                subscription[:customer][:default_source] = source if source
              end
            end
          when 'customer.invoice_settings.default_payment_method'
            customer_obj = subscription[:customer]
            customer_obj = customers[stripe_account][customer_obj] if customer_obj.is_a?(String)
            if customer_obj
              subscription[:customer] = customer_obj unless subscription[:customer].is_a?(Hash)
              pm_id = customer_obj.dig(:invoice_settings, :default_payment_method)
              if pm_id.is_a?(String)
                pm = payment_methods[pm_id]
                subscription[:customer][:invoice_settings][:default_payment_method] = pm if pm
              end
            end
          when /^customer\./
            # Generic customer expansion fallback
            customer_id = subscription[:customer]
            customer_id = customer_id[:id] if customer_id.is_a?(Hash)
            customer = customers[stripe_account][customer_id] if customer_id
            subscription[:customer] = customer if customer
          end
        end
      end

      def expand_payment_method(pi)
        pm_id = pi[:payment_method]
        if pm_id.is_a?(String) && payment_methods[pm_id]
          pi[:payment_method] = payment_methods[pm_id].clone
        end
      end

      def verify_active_status(subscription)
        id, status = subscription.values_at(:id, :status)

        if status == 'canceled'
          message = "No such subscription: '#{id}'"
          raise Stripe::InvalidRequestError.new(message, 'subscription', http_status: 404)
        end
      end
    end
  end
end
