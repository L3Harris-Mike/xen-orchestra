{
  each: $each
  isArray: $isArray
} = require 'underscore'

$js2xml = do ->
  {Builder} = require 'xml2js'
  builder = new Builder {
    xmldec: {
      # Do not include an XML header.
      #
      # This is not how this setting should be set but due to the
      # implementation of both xml2js and xmlbuilder-js it works.
      #
      # TODO: Find a better alternative.
      headless: true
    }
  }
  builder.buildObject.bind builder

$isVMRunning = do ->
  states = {
    'Halted': false
    'Paused': true
    'Running': true
    'Suspended': false
  }

  (VM) -> states[VM.power_state]

#=====================================================================

exports.create = ->
  # Validates and retrieves the parameters.
  {
    name
    template
    VIFs
    VDIs
  } = @getParams {
    # Name of the new VM.
    name: { type: 'string' }

    # TODO: add the install repository!

    # UUID of the template the VM will be created from.
    template: { type: 'string' }

    # Virtual interfaces to create for the new VM.
    VIFs: {
      type: 'array'
      items: {
        type: 'object'
        properties: {
          # UUID of the network to create the interface in.
          network: 'string'

          MAC: {
            optional: true # Auto-generated per default.
            type: 'string'
          }
        }
      }
    }

    # Virtual disks to create for the new VM.
    VDIs: {
      optional: true # If not defined, use the template parameters.
      type: 'array'
      items: {
        type: 'object' # TODO: Existing VDI?
        properties: {
          bootable: { type: 'boolean' }
          device: { type: 'string' } # TODO: ?
          size: { type: 'integer' }
          SR: { type: 'string' }
          type: { type: 'string' }
        }
      }
    }

    # Number of virtual CPUs to start the new VM with.
    CPUs: {
      optional: true # If not defined use the template parameters.
      type: 'integer'
    }
  }

  # Current user must be an administrator.
  @checkPermission 'admin'

  # Gets the template.
  template = @getObject template
  @throw 'NO_SUCH_OBJECT' unless template


  # Gets the corresponding connection.
  xapi = @getXAPI template

  # Clones the VM from the template.
  ref = xapi.call 'VM.clone', template.ref, name

  # Creates associated virtual interfaces.
  $each VIFs, (VIF) ->
    xapi.call 'VIF.create', {
      device: '0'
      MAC: VIF.MAC ? ''
      MTU: '1500'
      network: VIF.network
      other_config: {}
      qos_algorithm_params: {}
      qos_algorithm_type: ''
      VM: ref
    }

  # TODO: ? xapi.call 'VM.set_PV_args', ref, 'noninteractive'

  # Updates the number of existing vCPUs.
  if CPUs?
    xapi.call 'VM.set_VCPUs_at_startup', ref, CPUs

  if VDIs?
    # Transform the VDIs specs to conform to XAPI.
    $each VDIs, (VDI, key) ->
      VDI.bootable = if VDI.bootable then 'true' else 'false'
      VDI.size = "#{VDI.size}"
      VDI.sr = VDI.SR
      delete VDI.SR

      # Preparation for the XML generation.
      VDIs[key] = { $: VDI }

    # Converts the provision disks spec to XML.
    VDIs = $js2xml {
      provision: {
        disk: VDIs
      }
    }

    # Replace the existing entry in the VM object.
    try xapi.call 'VM.remove_from_other_config', ref, 'disks'
    xapi.call 'VM.add_to_other_config', ref, 'disks', VDIs

    # Creates the VDIs.
    xapi.call 'VM.provision', ref

  # The VM should be properly created.
  true

exports.migrate = ->
  {id, host} = @getParams {
    # Identifier of the VM to migrate.
    id: { type: 'string' }

    # Identifier of the host to migrate to.
    host: { type: 'string' }
  }

  # Current user must be an administrator.
  @checkPermission 'admin'

  try
    VM = @getObject id
    host = @getObject host
  catch
    @throw 'NO_SUCH_OBJECT'

  unless $isVMRunning VM
    @throw 'INVALID_PARAMS', 'The VM can only be migrated when running'

  xapi = @getXAPI VM

  xapi.call 'VM.pool_migrate', VM.ref, host.ref, {}

exports.set = ->
  params = @getParams {
    # Identifier of the VM to update.
    id: { type: 'string' }

    name_label: { type: 'string', optional: true }

    name_description: { type: 'string', optional: true }

    # Number of virtual CPUs to allocate.
    CPUs: { type: 'integer', optional: true }

    # Memory to allocate (in bytes).
    #
    # Note: static_min ≤ dynamic_min ≤ dynamic_max ≤ static_max
    memory: { type: 'integer', optional: true }
  }

  # Current user must be an administrator.
  @checkPermission 'admin'

  try
    VM = @getObject params.id
  catch
    @throw 'NO_SUCH_OBJECT'

  xapi = @getXAPI VM

  {ref} = VM

  # Memory.
  if 'memory' of params
    {memory} = params

    if memory < VM.memory.static[0]
      @throw(
        'INVALID_PARAMS'
        "cannot set memory below the static minimum (#{VM.memory.static[0]})"
      )

    if ($isVMRunning VM) and memory > VM.memory.static[1]
      @throw(
        'INVALID_PARAMS'
        "cannot set memory above the static maximum (#{VM.memory.static[1]}) "+
          "for a running VM"
      )

    if memory < VM.memory.dynamic[0]
      xapi.call 'VM.set_memory_dynamic_min', ref, "#{memory}"
    else if memory > VM.memory.static[1]
      xapi.call 'VM.set_memory_static_max', ref, "#{memory}"
    xapi.call 'VM.set_memory_dynamic_max', ref, "#{memory}"

  # Number of CPUs.
  if 'CPUs' of params
    {CPUs} = params

    if $isVMRunning VM
      if CPUs > VM.CPUs.max
        @throw(
          'INVALID_PARAMS'
          "cannot set CPUs above the static maximum (#{VM.CPUs.max}) "+
            "for a running VM"
        )
      xapi.call 'VM.set_VCPUs_number_live', ref, "#{CPUs}"
    else
      if CPUs > VM.CPUs.max
        xapi.call 'VM.set_VCPUs_max', ref, "#{CPUs}"
      xapi.call 'VM.set_VCPUs_at_startup', ref, "#{CPUs}"

  # Other fields.
  for param, fields of {
    'name_label'
    'name_description'
  }
    continue unless param of params

    for field in (if $isArray fields then fields else [fields])
      xapi.call "VM.set_#{field}", ref, "#{params[param]}"
