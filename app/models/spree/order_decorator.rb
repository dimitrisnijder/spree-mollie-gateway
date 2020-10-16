module Spree::OrderDecorator
  extend Spree::DisplayMoney
  money_methods :order_adjustment_total, :shipping_discount

  # Make sure the order confirmation is delivered when the order has been paid for.
  def finalize!
    # lock all adjustments (coupon promotions, etc.)
    all_adjustments.each(&:close)

    # update payment and shipment(s) states, and save
    updater.update_payment_state
    shipments.each do |shipment|
      shipment.update!(self)
      shipment.finalize! if paid? || authorized?
    end

    updater.update_shipment_state
    save!
    updater.run_hooks

    touch :completed_at

    if !confirmation_delivered? && (paid? || authorized?)
      deliver_order_confirmation_email
    end
  end

  def is_paid_with_mollie?
    payments.any? && payments.last&.payment_method&.type == 'Spree::PaymentMethod::MolliePayments'
  end

  def send_confirmation_email!
    if !confirmation_delivered? && (paid? || authorized?)
      deliver_order_confirmation_email
    end
  end

  def mollie_order
    Spree::Mollie::Order.new(self)
  end

  def successful_payment
    paid? || payments.any? {|p| p.after_pay_method? && p.authorized?}
  end

  alias paid_or_authorized? successful_payment

  def authorized?
    payments.last.authorized?
  end

  def order_adjustment_total
    adjustments.eligible.sum(:amount)
  end

  def has_order_adjustments?
    order_adjustment_total.abs > 0
  end

  def update_from_params(params, permitted_params, request_env = {})
    success = false
    @updating_params = params

    # Set existing card after setting permitted parameters because
    # rails would slice parameters containg ruby objects, apparently
    existing_card_id = @updating_params[:order] ? @updating_params[:order].delete(:existing_card) : nil

    attributes = if @updating_params[:order]
                    @updating_params[:order].permit(permitted_params).delete_if { |_k, v| v.nil? }
                  else
                    {}
                  end

    if existing_card_id.present?
      credit_card = CreditCard.find existing_card_id
      if credit_card.user_id != user_id || credit_card.user_id.blank?
        raise Core::GatewayError, Spree.t(:invalid_credit_card)
      end

      credit_card.verification_value = params[:cvc_confirm] if params[:cvc_confirm].present?

      attributes[:payments_attributes].first[:source] = credit_card
      attributes[:payments_attributes].first[:payment_method_id] = credit_card.payment_method_id
      attributes[:payments_attributes].first.delete :source_attributes
    end

    if attributes[:payments_attributes]
      attributes[:payments_attributes].first[:request_env] = request_env
    end

    success = update(attributes)
    set_shipments_cost if shipments.any?

    @updating_params = nil
    success
  end
end

Spree::Order.prepend(Spree::OrderDecorator)