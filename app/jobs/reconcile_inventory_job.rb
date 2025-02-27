class ReconcileInventoryJob < ApplicationJob
  queue_as :default

  def perform
    KuralisProduct.find_each do |product|
      InventoryService.reconcile_inventory(kuralis_product: product)
    end
  end
end 