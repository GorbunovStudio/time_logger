class ChangeTimeSpentToInt < ActiveRecord::Migration[5.2]
  def up
    change_column :time_loggers, :time_spent, :integer,
                  using: 'ROUND(time_spent * 3600)::integer', default: 0
  end

  def down
    change_column :time_loggers, :time_spent, :float,
                  using: 'time_spent::double precision / 3600.0', default: 0.0
  end
end
