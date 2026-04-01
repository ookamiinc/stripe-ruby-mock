module StripeMock
  module RequestHandlers
    module Helpers

      def non_integer_charge_amount?(params)
        return false unless params[:amount]
        return false if params[:amount].is_a?(Integer)
        return false if params[:amount].is_a?(String) && params[:amount].match?(/\A\d+\z/)

        true
      end

      def non_positive_charge_amount?(params)
        params[:amount] && params[:amount].to_i < 1
      end

    end
  end
end
