module Spree
  module Api
    module Retailops
      class SettlementController < Spree::Api::BaseController
        # "Settlement" subsystem - called by ROP when there are large changes in the status of the order.
        #
        # * First we add zero or more "packages" of things we were able to ship.
        #
        # * Then we flag the order as complete - this means ROP will not be shipping any more.  Often everything will have been shipped.  Sometimes not.  Oversells and short ships are af will add a negative
        #   adjustment if the order was short shipped.  Depending on
        #   configuration this may also cause automatic capturing or refunding of
        #   payments.
        #
        # * Then (later, and hopefully not at all) we can add refunds for
        #   inventory returned in ROP.

        # Package adding: This reflects a fairly major impedence mismatch
        # between ROP and Spree, insofar as Spree wants to create shipments at
        # checkout time and charge exact shipping, while ROP standard practice
        # is to charge an abstraction of shipping that's close enough on
        # average, and then decide the details of how this order will be
        # shipped when it's actually ready to go out the door.  Because of this
        # we have to fudge stuff a bit on shipment and recreate the Spree
        # shipments to reflect how ROP is actually shipping it, so that the
        # customer has the most actionable information.  A complication is that
        # Spree's shipping rates are tied to the shipment, and need to be
        # converted into order adjustments before we start mangling the
        # shipments.  Credit where due: this code is heavily inspired by some
        # code written by @schwartzdev for @dotandbo to handle an Ordoro
        # integration.
        def add_packages
          ActiveRecord::Base.transaction do
            find_order
            separate_shipment_costs
            params["packages"].try(:each) do |pkg|
              extract_items_into_package pkg
            end
          end
          render text: {}.to_json
        end

        # The Spree core appears to reflect two schools of thought on
        # refunding.  The user guide suggests that one reason you might edit
        # orders is if you could not ship them, which suggests handling short
        # ships by modifying the order itself, then refunding by the difference
        # between the new order value and the payment.  The core code itself
        # handles returns by creating an Adjustment for the returned
        # merchandise, and leaving the line items alone.
        #
        # We follow the latter approach because it allows us to keep RetailOps
        # as the sole authoritative source of refund values, avoiding useless
        # mismatch warnings.
        def mark_complete
          ActiveRecord::Base.transaction do
            find_order
            separate_shipment_costs
            create_short_adjustment
            delete_unshipped_shipments
          end
          settle_payments_if_desired
          render text: @settlement_results.to_json
        end

        def add_refund
          ActiveRecord::Base.transaction do
            find_order
            create_refund_adjustment
          end
          settle_payments_if_desired
          render text: @settlement_results.to_json
        end

        private
          # What order is being settled?
          def find_order
            @order = Order.find_by!(number: params["order_refnum"].to_s)
            authorize! :update, @order
          end

          # To prevent Spree from trying to recalculate shipment costs as we
          # create and delete shipments, transfer shipping costs to order
          # adjustments
          def separate_shipment_costs
            extracted_total = 0.to_d
            @order.shipments.each do |shipment|
              # Spree 2.1.x: shipment costs are expressed as order adjustments linked through source to the shipment
              # Spree 2.2.x: shipments have a cost which is authoritative, and one or more adjustments (shiptax, etc)
              cost = if shipment.respond_to?(:adjustment)
                shipment.adjustment.try(:amount) || 0.to_d
              else
                shipment.cost + shipment.adjustment_total
              end

              if cost > 0
                extracted_total += cost
                shipment.adjustment.open if shipment.respond_to? :adjustment
                shipment.adjustments.delete_all if shipment.respond_to? :adjustments
                shipment.shipping_rates.delete_all
                shipment.add_shipping_method(rop_tbd_method, true)
                shipment.save!
              end
            end

            if extracted_total > 0
              # TODO: is Standard Shipping the best name for this?  Should i18n happen?
              @order.adjustments.create(amount: extracted_total, label: "Standard Shipping", mandatory: false)
              @order.save!
            end
          end

          def extract_items_into_package(pkg)
            number = 'P' + pkg["id"].to_i
            shipcode = pkg["shipcode"].to_s
            tracking = pkg["tracking"].to_s
            line_items = pkg["contents"].to_a
            from_location = pkg["from"].to_s
            date_shipped = Time.parse(pkg["date"].to_s)

            from_location = Spree::StockLocation.find_by(name: from_location) || raise("Stock location to ship from not present in Spree: #{from_location}")

            if @order.shipments.find_by(number: number)
              return # idempotence
              # TODO: not sure if we should allow adding stuff after the shipment ships
            end

            shipment = @order.shipments.build

            shipment.number = number
            shipment.stock_location = from_location

            existing_units = @order.inventory_units.reject{ |u| u.shipped? || u.returned? }.group_by(&:line_item_id)

            line_items.each do |item|
              line_item = @order.line_items.find(item["id"].to_i)
              quantity = item["quantity"].to_i

              # move existing inventory units
              reusable = existing_units[line_item.id] || []
              reused = reusable.slice!(0, quantity)

              shipment.inventory_units.concat(reused)
              quantity -= reused.count

              # limit transfered units to ordered units
            end

            shipment.shipping_rates.delete_all
            shipment.cost = 0.to_d

            if shipment.respond_to? :retailops_set_tracking
              shipment.retailops_set_tracking(pkg)
            else
              shipment.add_shipping_method(advisory_method(shipcode), true)
              shipment.tracking = tracking
              shipment.created_at = date_shipped
            end

            shipment.state = 'ready'
            shipment.finalize!
            shipment.ship!
            shipment.save!

            @order.shipments.each { |s| s.reload; s.destroy if s.inventory_units.empty? }
            @order.update!
          end

          def create_short_adjustment
            raise "Not implemented"
          end

          def delete_unshipped_shipments
            @order.shipments.reject(&:shipped?).each{ |s| s.cancel!; s.destroy! }
          end

          def create_refund_adjustment
            raise "Not implemented"
          end

          # If something goes wrong with a multi-payment order, we want to log
          # it and keep going.  We may get what we need from other payments,
          # otherwise we want to make as much progress as possible...
          def rescue_gateway_error
            yield
          rescue Spree::Core::GatewayError => e
            @settlement_results["errors"] << e.message
          end

          # Try to get payment on a completed order as tidy as possible subject
          # to your automation settings.  For maximum idempotence, returns the
          # new state so that RetailOps can reconcile its own notion of the
          # payment state.
          def settle_payments_if_desired
            @settlement_results = { "errors" => [], "status" => [] }

            op = nil

            while params["ok_capture"] && @order.outstanding_balance > 0 && op = @order.payments.detect { |opp| opp.pending? && opp.amount > 0 && opp.amount <= @order.outstanding_balance }
              rescue_gateway_error { op.capture! }
            end

            while params["ok_partial_capture"] && @order.outstanding_balance > 0 && op = @order.payments.detect { |op| opp.pending? && opp.amount > 0 && opp.amount > @order.outstanding_balance }
              if op.method(:capture!).parameters.count > 0
                # Spree 2.2.x: can capture with an amount
                rescue_gateway_error { op.capture! @order.display_outstanding_balance.money.cents }
              else
                # Spree 2.1.x: have to fudge the payment
                op.amount = @order.outstanding_balance
                rescue_gateway_error { op.capture! }
              end
            end

            while params["ok_void"] && @order.outstanding_balance <= 0 && op = @order.payments.detect { |opp| opp.pending? && opp.amount > 0 }
              rescue_gateway_error { op.void_transaction! }
            end

            while params["ok_refund"] && @order.outstanding_balance < 0 && op = @order.payments.detect { |opp| opp.completed? && opp.can_credit? }
              rescue_gateway_error { op.credit! } # remarkably, THIS one picks the right amount for us
            end

            status = []
            # collect payment data
            @order.payments.select{|op| op.amount > 0}.each do |op|
              status << { "id" => op.id, "state" => op.state, "amount" => op.amount, "credit" => op.offsets_total.abs }
            end

            @settlement_results = { "errors" => errors, "status" => status }
          end

          def rop_tbd_method
            advisory_method(params["partial_ship_name"] || "Partially shipped")
          end

          def advisory_method(name)
            use_any_method = params["use_any_method"]
            @advisory_methods ||= {}
            unless @advisory_methods[name]
              @advisory_methods[name] = ShippingMethod.where(admin_name: name).detect { |s| use_any_method || s.calculator < Spree::Calculator::Shipping::RetailopsAdvisory }
            end

            unless @advisory_methods[name]
              raise "Advisory shipping method #{name} does not exist and automatic creation is disabled" if params["no_auto_shipping_methods"]
              @advisory_methods[name] = ShippingMethod.create!(name: name, admin_name: name) do |m|
                m.calculator = Spree::Calculator::Shipping::RetailopsAdvisory.new
                m.shipping_categories << ShippingCategory.first
              end
            end
            @advisory_methods[name]
          end
      end
    end
  end
end