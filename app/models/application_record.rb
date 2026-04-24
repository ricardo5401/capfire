# frozen_string_literal: true

# Abstract base class for every AR model in Capfire.
class ApplicationRecord < ActiveRecord::Base
  self.abstract_class = true
end
