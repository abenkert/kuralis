class WarehousesController < AuthenticatedController
  layout "authenticated"

  def index
    @warehouses = current_shop.warehouses.order(is_default: :desc, name: :asc)
  end

  def new
    @warehouse = current_shop.warehouses.build
  end

  def create
    @warehouse = current_shop.warehouses.build(warehouse_params)

    if @warehouse.save
      respond_to do |format|
        format.html { redirect_to settings_path, notice: "Warehouse was successfully created." }
        format.turbo_stream {
          render turbo_stream: [
            turbo_stream.update("modal_content", ""),
            turbo_stream.replace("warehouses_list", partial: "settings/warehouses_list", locals: { shop: current_shop })
          ]
        }
      end
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @warehouse = current_shop.warehouses.find(params[:id])
  end

  def update
    @warehouse = current_shop.warehouses.find(params[:id])

    if @warehouse.update(warehouse_params)
      respond_to do |format|
        format.html { redirect_to settings_path, notice: "Warehouse was successfully updated." }
        format.turbo_stream {
          render turbo_stream: [
            turbo_stream.update("modal_content", ""),
            turbo_stream.replace("warehouses_list", partial: "settings/warehouses_list", locals: { shop: current_shop })
          ]
        }
      end
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @warehouse = current_shop.warehouses.find(params[:id])

    if @warehouse.is_default? && current_shop.warehouses.count == 1
      redirect_to settings_path, alert: "Cannot delete the only default warehouse."
      return
    end

    @warehouse.destroy
    redirect_to settings_path, notice: "Warehouse was successfully removed."
  end

  private

  def warehouse_params
    params.require(:warehouse).permit(
      :name,
      :address1,
      :address2,
      :city,
      :state,
      :postal_code,
      :country_code,
      :is_default,
      :active
    )
  end
end
