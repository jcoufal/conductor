#
#   Copyright 2011 Red Hat, Inc.
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.
#

# == Schema Information
#
# Table name: deployments
#
#  id                     :integer         not null, primary key
#  name                   :string(1024)    not null
#  realm_id               :integer
#  owner_id               :integer
#  pool_id                :integer         not null
#  lock_version           :integer         default(0)
#  created_at             :datetime
#  updated_at             :datetime
#  frontend_realm_id      :integer
#  deployable_xml         :text
#  scheduled_for_deletion :boolean         default(FALSE), not null
#  uuid                   :text            not null
#

require 'util/deployable_xml'
require 'util/config_server_util'

class Deployment < ActiveRecord::Base
  acts_as_paranoid

  include PermissionedObject
  class << self
    include CommonFilterMethods
  end

  belongs_to :pool
  belongs_to :pool_family

  has_many :instances, :dependent => :destroy

  belongs_to :realm
  belongs_to :frontend_realm

  has_many :permissions, :as => :permission_object, :dependent => :destroy,
           :include => [:role],
           :order => "permissions.id ASC"
  has_many :derived_permissions, :as => :permission_object, :dependent => :destroy,
           :include => [:role],
           :order => "derived_permissions.id ASC"

  belongs_to :owner, :class_name => "User", :foreign_key => "owner_id"

  has_many :events, :as => :source, :dependent => :destroy,
           :order => 'events.id ASC'

  has_many :provider_accounts, :through => :instances

  after_create "assign_owner_roles(owner)"

  scope :ascending_by_name, :order => 'deployments.name ASC'

  before_validation :replace_special_characters_in_name
  validates_presence_of :pool_id
  validates_presence_of :name
  validates_uniqueness_of :name, :scope => [:pool_id, :deleted_at]
  validates_length_of :name, :maximum => 50
  validates_presence_of :owner_id
  validate :pool_must_be_enabled
  before_destroy :destroyable?
  before_create :inject_launch_parameters
  before_create :generate_uuid
  before_create :set_pool_family
  before_create :set_new_state
  after_save :log_state_change

  USER_MUTABLE_ATTRS = ['name']

  STATE_NEW                  = "new"
  STATE_PENDING              = "pending"
  STATE_RUNNING              = "running"
  STATE_INCOMPLETE           = "incomplete"
  STATE_SHUTTING_DOWN        = "shutting_down"
  STATE_STOPPED              = "stopped"
  STATE_FAILED               = "failed"
  STATE_ROLLBACK_IN_PROGRESS = "rollback_in_progress"
  STATE_ROLLBACK_COMPLETE    = "rollback_complete"
  STATE_ROLLBACK_FAILED      = "rollback_failed"

  STATES = [STATE_NEW, STATE_PENDING, STATE_RUNNING, STATE_INCOMPLETE,
            STATE_SHUTTING_DOWN, STATE_STOPPED, STATE_FAILED,
            STATE_ROLLBACK_IN_PROGRESS, STATE_ROLLBACK_COMPLETE,
            STATE_ROLLBACK_FAILED]

  validate :validate_xml
  validate :validate_launch_parameters

  def validate_xml
    begin
      deployable_xml.validate!
    rescue DeployableXML::ValidationError => e
      errors.add(:deployable_xml, e.message)
    rescue Nokogiri::XML::SyntaxError => e
      errors.add(:base, I18n.t("deployments.errors.not_valid_deployable_xml", :msg => "#{e.message}"))
    end
  end

  def validate_launch_parameters
    launch_parameters.each do |asm, services|
      services.each do |service, params|
        params.each do |param, value|
          if value.blank?
            errors.add(:launch_parameters, "#{asm}.#{service}.#{param} cannot be blank")
          end
        end
      end
  end
  end

  def pool_must_be_enabled
    errors.add(:pool, I18n.t('pools.errors.must_be_enabled')) unless pool and pool.enabled?
    errors.add(:pool, I18n.t('pools.errors.providers_disabled')) if pool and pool.pool_family.all_providers_disabled?
  end

  def perm_ancestors
    super + [pool, pool_family]
  end
  def derived_subtree(role = nil)
    subtree = super(role)
    subtree += instances if (role.nil? or role.privilege_target_match(Instance))
    subtree
  end
  def self.additional_privilege_target_types
    [Instance]
  end

  def get_action_list(user=nil)
    # FIXME: how do actions and states interact for deployments?
    # For instances the list comes from the provider based on current state.
    # Deployments don't currently have an explicit state field, but
    # something could be calculated from associated instances.
    ["start", "stop", "reboot"]
  end

  def valid_action?(action)
    return get_action_list.include?(action) ? true : false
  end

  def destroyable?
    instances.all? {|i| i.destroyable? }
  end

  def stop_instances_and_destroy!
    if destroyable?
      destroy_deployment_config
      destroy
      return
    end

    self.state = Deployment::STATE_SHUTTING_DOWN
    save!
    if instances.all? {|i| i.destroyable? or i.state == Instance::STATE_RUNNING}
      destroy_deployment_config
      # The deployment will be destroyed from an InstanceObserver callback once
      # all instances are stopped.
      self.scheduled_for_deletion = true
      self.save!

      # stop all deployment's instances
      instances.each do |instance|
        next unless instance.state == Instance::STATE_RUNNING

        @task = instance.queue_action(instance.owner, 'stop')
        unless @task
          raise I18n.t("deployments.errors.cannot_stop")
        end
        Taskomatic.stop_instance(@task)
      end
    else
      raise I18n.t("deployments.errors.all_stopped")
    end
  end

  def self.stoppable_inaccessible_instances(deployments)
    failed_accounts = {}
    res = []
    deployments.each do |d|
      next unless acc = d.provider_account
      failed_accounts[acc.id] = acc.connect.nil? unless failed_accounts.has_key?(acc.id)
      next unless failed_accounts[acc.id]
      res += d.instances.stoppable_inaccessible
    end
    res
  end

  def launch_parameters
    @launch_parameters ||= {}
  end

  def launch_parameters=(launch_parameters)
    @launch_parameters = launch_parameters
  end

  def create_and_launch(session, user)
    begin
      rollback_active_record_state! do
        # deployment's attrs are not reset on rollback,
        # rollback_active_record_state! takes care of this
        transaction do
          create_instances_with_params!(session, user)
          launch!(user)
        end
      end
      return true
    rescue
      errors.add(:base, $!.message)
      logger.error $!.message
      logger.error $!.backtrace.join("\n    ")
    end
    false
  end

  def launch!(user)
    self.state = STATE_PENDING
    save!
    all_inst_match, account, errs = find_match_with_common_account

    unless all_inst_match
      raise I18n.t('deployments.errors.match_not_found',
                   :errors => errs.join(", "))
    end

    if deployable_xml.requires_config_server?
      # the instance configurations need to be generated from the entire set of
      # instances (and not each individual instance) in order to do parameter
      # dependency resolution across the set
      config_server = account.config_server
      instance_configs = ConfigServerUtil.instance_configs(self,
                                                           instances,
                                                           config_server)
    else
      config_server = nil
      instance_configs = {}
    end


    # TODO: in follow up patch there should be only delayed job call
    # on this place
    # For now, we just call DC create intance method on foreground, if an error
    # occurs (for example DC API is not running, or config server is not
    # running), then CREATE_FAILED is set in instance.launch!
    instances.each do |instance|
      match = all_inst_match.find{|m| m.instance.id == instance.id}
      begin
        instance.launch!(match,
                         user,
                         config_server,
                         instance_configs[instance.uuid])
      rescue
        errors.add(:base,
                   "#{instance.name}: #{$!.message.to_s.split("\n").first}")
        logger.error $!.message
        logger.error $!.backtrace.join("\n    ")

        # be default launching of instances is terminated if an error occurs,
        # user can set "partial_launch" attribute - launch request is then
        # sent for all deployment's instances
        break unless partial_launch
      end
    end
    true
  end

  def self.list(order_field, order_dir)
    Deployment.all(:include => :owner,
                   :order => (order_field || 'name') +' '+ (order_dir || 'asc'))
  end

  def valid_deployable_xml?(xml)
    begin
      self.deployable_xml = DeployableXML.new(xml)
      deployable_xml.validate!
      true
    rescue
      errors.add(:base, I18n.t("deployments.errors.not_valid_deployable_xml", :msg => "#{$!.message}"))
      false
    end
  end

  def deployable_xml
    @deployable_xml ||= DeployableXML.new(self[:deployable_xml].to_s)
  end

  def properties
    result = {
      :name => name,
      :created => created_at,
      :pool => pool.name
    }

    result[:owner] = "#{owner.first_name}  #{owner.last_name}" if owner.present?

    result
  end

  def provider
    if deleted?
      inst = instances.unscoped.joins(:provider_account => :provider).first
    else
      inst = instances.joins(:provider_account => :provider).first
    end
    inst && inst.provider_account && inst.provider_account.provider
  end

  def provider_account
    if deleted?
      inst = instances.unscoped.joins(:provider_account).first
    else
      inst = instances.joins(:provider_account).first
    end
    inst && inst.provider_account
  end

  # we try to create an instance for each assembly and check
  # if a match is found
  def check_assemblies_matches(session, user)
    errs = []
    begin
      deployable_xml.assemblies.each do |assembly|
        hw_profile = permissioned_frontend_hwprofile(session, user, assembly.hwp)
        raise I18n.t('deployments.flash.error.no_hwp_permission', :hwp => assembly.hwp) unless hw_profile
        instance = Instance.new(
          :deployment => self,
          :name => "#{name}/#{assembly.name}",
          :frontend_realm => frontend_realm,
          :pool => pool,
          :image_uuid => assembly.image_id,
          :image_build_uuid => assembly.image_build,
          :assembly_xml => assembly.to_s,
          :state => Instance::STATE_NEW,
          :owner => user,
          :hardware_profile => hw_profile
        )
        instances << instance
        possibles, errors = instance.matches
        if possibles.empty? and not errors.empty?
          raise Aeolus::Conductor::MultiError::UnlaunchableAssembly.new(I18n.t('deployments.flash.error.not_launched'), errors)
        end
      end

      match, account, errors = find_match_with_common_account
      if match.nil? and not errors.empty?
        raise Aeolus::Conductor::MultiError::UnlaunchableAssembly.new(I18n.t('deployments.flash.error.not_launched'), errors)
      end

      deployment_errors = []
      deployment_errors << I18n.t('instances.errors.pool_quota_reached') unless pool.quota.can_start?(instances)
      deployment_errors << I18n.t('instances.errors.pool_family_quota_reached') unless pool.pool_family.quota.can_start?(instances)
      deployment_errors << I18n.t('instances.errors.user_quota_reached') unless user.quota.can_start?(instances)

      if not deployment_errors.empty?
        raise Aeolus::Conductor::MultiError::UnlaunchableAssembly.new(I18n.t('deployments.flash.error.not_launched'), deployment_errors)
      end
    rescue
      errs << $!.message
    end
    errs
  end

  def all_instances_running?
    instances.deployed.count == instances.count
  end

  def any_instance_running?
    instances.any? {|i| i.state == Instance::STATE_RUNNING }
  end

  def uptime_1st_instance
    return nil if events.empty?

    first_running = events.find_by_status_code(:first_running)
    if instances.deployed.empty?
      all_stopped = events.find_last_by_status_code(:all_stopped)
      if all_stopped && first_running && all_stopped.event_time > first_running.event_time
        all_stopped.event_time - first_running.event_time
      else
        nil
      end
    else
      if first_running
        Time.now.utc - first_running.event_time
      else
        nil
      end
    end
  end

  def uptime_all
    return nil if events.empty?

    all_running = events.find_last_by_status_code(:all_running)
    some_stopped = events.find_last_by_status_code(:some_stopped)
    all_stopped = events.find_last_by_status_code(:all_stopped)

    if instances.deployed.count == instances.count && all_running
      Time.now.utc - all_running.event_time
    elsif instances.count > 1 && all_running && some_stopped
      some_stopped.event_time - all_running.event_time
    elsif all_stopped && all_running && all_stopped.event_time > all_running.event_time
      all_stopped.event_time - all_running.event_time
    else
      nil
    end
  end

  # A deployment "starts" when _all_ instances begin to run
  def start_time
    if instances.deployed.count == instances.count && ev = events.find_by_status_code(:all_running)
      ev.event_time
    else
      nil
    end
  end

  # A deployment "ends" when one or more instances stop, assuming they were ever all-running
  def end_time
    if events.find_by_status_code(:all_running)
      ev = events.find_by_status_code(:some_stopped) || events.find_by_status_code(:all_stopped)
      ev.present? ? ev.event_time : nil
    else
      nil
    end
  end

  def as_json(options={})
    json = super(options).merge({
      :deployable_xml_name => deployable_xml.name,
      :status => state,
      :translated_state => I18n.t("deployments.status.#{state}"),
      :status_description => I18n.t("deployments.status_description.#{state}"),
      :instances_count => instances.count,
      :failed_instances_count => failed_instances.count,
      :instances_count_text => I18n.t('instances.instances', :count => instances.count.to_i),
      :uptime => ApplicationHelper.count_uptime(uptime_1st_instance),
      :pool => {
        :name => pool.name,
        :id => pool.id,
      },
      :created_at => created_at.to_s
    })

    json[:owner] = owner.name if owner.present?

    deployment_provider = provider
    if deployment_provider
      json[:provider] = {
        :name => deployment_provider.provider_type.name,
        :id => deployment_provider.id,
      }
    end

    json
  end

  def failed_instances
    instances.select {|instance| instance.failed?}
  end

  def update_state(changed_instance)
    transition_method = "state_transition_from_#{state}".to_sym
    send(transition_method, changed_instance) if self.respond_to?(transition_method, true)
    if state_changed?
      save!
      true
    else
      false
    end
  end

  PRESET_FILTERS_OPTIONS = []

  private

  def self.apply_search_filter(search)
    # TODO: after upgrading to 3.1 the SQL join statement can be done in Rails way by adding a has_many association to providers through provider_accounts
    #       (Rails before version 3.1 does not support nested associations with through param)
    if search
      includes(:pool, :provider_accounts => :provider).
          joins("LEFT OUTER JOIN provider_types ON provider_types.id = providers.provider_type_id").
          where("lower(pools.name) LIKE :search OR lower(deployments.name) LIKE :search OR lower(provider_types.name) LIKE :search",
                :search => "%#{search.downcase}%")
    else
      scoped
    end
  end

  def permissioned_frontend_hwprofile(session, user, hwp_name)
    HardwareProfile.list_for_user(session, user, Privilege::VIEW).where('hardware_profiles.name = :name AND provider_id IS NULL', {:name => hwp_name}).first
  end

  def inject_launch_parameters
    launch_parameters.each_pair do |assembly, svcs|
      svcs.each_pair do |service, params|
        params.each_pair do |param, value|
          deployable_xml.set_parameter_value(assembly, service, param, value)
        end
      end
    end
  end

  def destroy_deployment_config
    # the implication here is that if there is an instance in this deployment
    # with userdata, then a config server was associated with this deployment;
    # further, the config server associated with one instance is the same config
    # server used for all instances in the deployment
    # this logic could easily change
    if instances.any? {|instance| instance.user_data}
      # guard against the provider_account being nil
      if instances.first.provider_account
        configserver = instances.first.provider_account.config_server
        configserver.delete_deployment_config(uuid) if configserver
      end
    end
  end

  # Find account (w/ highest priority) where all instances can be launched.
  # 1. find all matches for each instance
  # 2. for each account (ordered by priority) try to find match for each
  # instance
  def find_match_with_common_account
    errors = []
    all_matches = instances.map do |instance|
      m, e = instance.matches
      errors = e.map {|e| "#{instance.name}: #{e}"}
      m
    end

    pool.pool_family.provider_accounts_by_priority.each do |account|
      matches_by_account = all_matches.map do |m|
        m.find {|m| m.provider_account.id == account.id}
      end
      next if matches_by_account.include?(nil)
      unless account.quota.can_start? instances
        errors << I18n.t('instances.errors.provider_account_quota_too_low', :match_provider_account => account)
        next
      end
      return [matches_by_account, account, errors] unless matches_by_account.include?(nil)
    end
    [nil, nil, errors]
  end

  def generate_uuid
    self[:uuid] = UUIDTools::UUID.timestamp_create.to_s
  end

  def replace_special_characters_in_name
    name.gsub!(/[^a-zA-Z0-9]+/, '-') if !name.nil?
  end

  def set_pool_family
    self[:pool_family_id] = pool.pool_family_id
  end

  def create_instances_with_params!(session, user)
    errors = {}
    deployable_xml.assemblies.each do |assembly|
      hw_profile = permissioned_frontend_hwprofile(session, user, assembly.hwp)
      raise I18n.t('deployments.flash.error.no_hwp_permission', :hwp => assembly.hwp) unless hw_profile
      Instance.transaction do
        instance = Instance.create!(
          :deployment => self,
          :name => "#{name}/#{assembly.name}",
          :frontend_realm => frontend_realm,
          :pool => pool,
          :image_uuid => assembly.image_id,
          :image_build_uuid => assembly.image_build,
          :assembly_xml => assembly.to_s,
          :state => Instance::STATE_NEW,
          :owner => user,
          :hardware_profile => hw_profile
        )
        assembly.services.each do |service|
          service.parameters.each do |parameter|
            if not parameter.reference?
              param = InstanceParameter.create!(
                :instance => instance,
                :service => service.name,
                :name => parameter.name,
                :type => parameter.type,
                :value => parameter.value
              )
            end
          end
        end
        self.instances << instance
      end
    end
  end

  def set_new_state
    self.state ||= STATE_NEW
  end

  def state_transition_from_pending(instance)
    if instances.all? {|i| i.state == Instance::STATE_RUNNING}
      self.state = STATE_RUNNING
    elsif partial_launch and instances.all? {|i| i.failed_or_running?}
      self.state = STATE_RUNNING
    elsif !partial_launch and Instance::FAILED_STATES.include?(instance.state)
      self.events << Event.create(
        :source => self,
        :event_time => DateTime.now,
        :status_code => 'instance_launch_failed',
        :summary => "Failed to launch instance #{instance.name}, doing rollback"
      )
      # TODO: now this is done in instance's after_update callback - as part
      # of instance save transaction - this might be done on background by
      # using delayed_job
      deployment_rollback
    end
  end

  def state_transition_from_running(instance)
    if instance.state != STATE_RUNNING
      self.state = STATE_INCOMPLETE
    end
  end

  def state_transition_from_incomplete(instance)
    if instances.all? {|i| i.state == Instance::STATE_RUNNING}
      self.state = STATE_RUNNING
    end
  end

  def state_transition_from_shutting_down(instance)
    if instance.state == Instance::STATE_STOPPED and instances.all? {|i| i.inactive?}
      self.state = STATE_STOPPED
    end
  end

  def state_transition_from_rollback_in_progress(instance)
    # TODO: distinguish if an instance was created on provider side
    # or error occurred on create_instance request - in such case
    # the instance has not to be rollbacked
    if Instance::ACTIVE_FAILED_STATES.include?(instance.state)
      # if this instance stop failed, whole deployment rollback failed
      self.state = STATE_ROLLBACK_FAILED
      cleanup_failed_launch
    elsif instance.state == Instance::STATE_RUNNING
      deployment_rollback
    elsif instances.all? {|i| i.inactive? or i.state == Instance::STATE_NEW}
      # some other instances might be failed (because their
      # launch failed), but it shouldn't be a problem if all
      # running instances stopped correctly
      self.state = STATE_ROLLBACK_COMPLETE
    end
  end

  def deployment_rollback
    unless self.state == STATE_ROLLBACK_IN_PROGRESS
      self.state = STATE_ROLLBACK_IN_PROGRESS
      save!
    end

    if instances.all? {|i| i.inactive? or i.state == Instance::STATE_NEW}
      self.state = STATE_ROLLBACK_COMPLETE
      save!
      return
    end

    error_occured = false
    instances.running.each do |instance|
      begin
        instance.stop(nil)
      rescue
        error_occured = true
        self.events << Event.create(
          :source => self,
          :event_time => DateTime.now,
          :status_code => 'instance_stop_failed',
          :summary => "Failed to stop instance #{instance.name}",
          :description => $!.message
        )
        logger.error $!.message
        logger.error $!.backtrace.join("\n  ")
      end
    end
    if error_occured
      cleanup_failed_launch
      self.state = STATE_ROLLBACK_FAILED
      save!
    end
  end

  def log_state_change
    if state_changed?
      self.events << Event.create(
        :source => self,
        :event_time => DateTime.now,
        :status_code => self.state,
        :summary => "State changed to #{self.state}"
      )
    end
  end

  def cleanup_failed_launch
    instances.in_new_state.each do |instance|
      instance.update_attribute(:state, Instance::STATE_CREATE_FAILED)
    end
  end
end
