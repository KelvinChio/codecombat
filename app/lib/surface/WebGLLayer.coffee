SpriteBuilder = require 'lib/sprites/SpriteBuilder'
CocoClass = require 'lib/CocoClass'
WebGLSprite = require './WebGLSprite'
{SpriteContainerLayer} = require 'lib/surface/Layer'

module.exports = class WebGLLayer extends CocoClass

  _.extend(WebGLLayer.prototype, Backbone.Events)

  actionRenderState: null
  needToRerender: false
  toRenderBundles: null
  willRender: false
  buildAutomatically: true
  buildAsync: true
  resolutionFactor: SPRITE_RESOLUTION_FACTOR
  defaultActions: ['idle', 'die', 'move', 'move_back', 'move_side', 'move_fore', 'attack']
  numThingsLoading: 0
  cocoSprites: null
  spriteSheet: null
  spriteContainer: null
  
  constructor: (@layerOptions) ->
    @layerOptions ?= {}
    super()
    @initializing = true
    @spriteSheet = @_renderNewSpriteSheet(false) # builds an empty spritesheet
    @spriteContainer = new SpriteContainerLayer(@spriteSheet, @layerOptions)
    @actionRenderState = {}
    @toRenderBundles = []
    @cocoSprites = []
    @initializing = false
    
  setDefaultActions: (@defaultActions) ->
    
  renderGroupingKey: (thangType, grouping, colorConfig) ->
    key = thangType.get('slug')
    if colorConfig?.team
      key += "(#{colorConfig.team.hue},#{colorConfig.team.saturation},#{colorConfig.team.lightness})"
    key += '.'+grouping if grouping
    key
    
  addCocoSprite: (cocoSprite) ->
    @cocoSprites.push cocoSprite
    @loadThangType(cocoSprite.thangType)
    @addDefaultActionsToRender(cocoSprite)
    @setImageObjectToCocoSprite(cocoSprite)
    # TODO: actually add it as a child

  loadThangType: (thangType) ->
    if not thangType.isFullyLoaded()
      thangType.setProjection null
      thangType.fetch() unless thangType.loading
      @numThingsLoading++
      @listenToOnce(thangType, 'sync', @somethingLoaded)
    else if thangType.get('raster') and not thangType.loadedRaster
      thangType.loadRasterImage()
      @listenToOnce(thangType, 'raster-image-loaded', @somethingLoaded)
      @numThingsLoading++

  somethingLoaded: (thangType) ->
    @numThingsLoading--
    @loadThangType(thangType) # might need to load the raster image object
    for cocoSprite in @cocoSprites
      if cocoSprite.thangType is thangType
        @addDefaultActionsToRender(cocoSprite)
    @renderNewSpriteSheet()

  addDefaultActionsToRender: (cocoSprite) ->
    needToRender = false
    if cocoSprite.thangType.get('raster')
      @upsertActionToRender(cocoSprite.thangType)
    else
      for action in _.values(cocoSprite.thangType.getActions())
        continue unless action.name in @defaultActions
        @upsertActionToRender(cocoSprite.thangType, action.name, cocoSprite.options.colorConfig)

  upsertActionToRender: (thangType, actionName, colorConfig) ->
    groupKey = @renderGroupingKey(thangType, actionName, colorConfig)
    return false if @actionRenderState[groupKey] isnt undefined
    @actionRenderState[groupKey] = 'need-to-render'
    @toRenderBundles.push({thangType: thangType, actionName: actionName, colorConfig: colorConfig})
    return true if @willRender or not @buildAutomatically
    @willRender = _.defer => @renderNewSpriteSheet()
    return true
    
  renderNewSpriteSheet: ->
    @willRender = false
    return if @numThingsLoading
    @_renderNewSpriteSheet()
    
  _renderNewSpriteSheet: (async) ->
    async ?= @buildAsync
    builder = new createjs.SpriteSheetBuilder()
    groups = _.groupBy(@toRenderBundles, ((bundle) -> @renderGroupingKey(bundle.thangType, '', bundle.colorConfig)), @)
    for bundleGrouping in _.values(groups)
      thangType = bundleGrouping[0].thangType
      colorConfig = bundleGrouping[0].colorConfig
      actionNames = (bundle.actionName for bundle in bundleGrouping)
      args = [thangType, colorConfig, actionNames, builder]
      if thangType.get('raw')
        if thangType.get('renderStrategy') is 'container'
          @renderContainers(args...)
        else
          @renderSpriteSheet(args...)
      else
        @renderRasterImage(thangType, builder)
        
    if not _.size(groups)
      emptiness = new createjs.Container()
      emptiness.setBounds(0, 0, 1, 1)
      builder.addFrame(emptiness)

    if async
      builder.buildAsync()
      builder.on 'complete', @onBuildSpriteSheetComplete, @, true, builder
    else
      sheet = builder.build()
      @onBuildSpriteSheetComplete(null, builder)
      return sheet

  onBuildSpriteSheetComplete: (e, builder) ->
    return if @initializing
    @spriteSheet = builder.spriteSheet
    oldLayer = @spriteContainer 
    @spriteContainer = new SpriteContainerLayer(@spriteSheet, @layerOptions)
    for cocoSprite in @cocoSprites
      @setImageObjectToCocoSprite(cocoSprite)
    for prop in ['scaleX', 'scaleY', 'regX', 'regY']
      @spriteContainer[prop] = oldLayer[prop]
    if parent = oldLayer.parent
      index = parent.getChildIndex(oldLayer)
      parent.removeChildAt(index)
      parent.addChildAt(@spriteContainer, index)
    @layerOptions.camera?.updateZoom(true)
    @spriteContainer.updateLayerOrder()
    @trigger 'new-spritesheet'

  renderContainers: (thangType, colorConfig, actionNames, spriteSheetBuilder) ->
    containersToRender = {}
    for actionName in actionNames
      action = _.find(thangType.getActions(), {name: actionName})
      if action.container
        containersToRender[action.container] = true
      else if action.animation
        animationContainers = @getContainersForAnimation(thangType, action.animation)
        containersToRender[container.gn] = true for container in animationContainers
    
    spriteBuilder = new SpriteBuilder(thangType, {colorConfig: colorConfig})
    for containerGlobalName in _.keys(containersToRender)
      containerKey = @renderGroupingKey(thangType, containerGlobalName, colorConfig)
      container = spriteBuilder.buildContainerFromStore(containerGlobalName)
      frame = spriteSheetBuilder.addFrame(container)
      spriteSheetBuilder.addAnimation(containerKey, [frame], false)

  getContainersForAnimation: (thangType, animation) ->
    containers = thangType.get('raw').animations[animation].containers
    for animation in thangType.get('raw').animations[animation].animations
      containers = containers.concat(@getContainersForAnimation(thangType, animation.gn))
    return containers
      
  renderSpriteSheet: (thangType, colorConfig, actionNames, spriteSheetBuilder) ->
    actionObjects = _.values(thangType.getActions())
    animationActions = []
    for a in actionObjects
      continue unless a.animation
      continue unless a.name in actionNames
      animationActions.push(a)
    
    spriteBuilder = new SpriteBuilder(thangType, {colorConfig: colorConfig})
    
    animationGroups = _.groupBy animationActions, (action) -> action.animation
    for animationName, actions of animationGroups
      renderAll = _.any actions, (action) -> action.frames is undefined
      scale = actions[0].scale or thangType.get('scale') or 1
      mc = spriteBuilder.buildMovieClip(animationName, null, null, null, {'temp':0})
      
      if renderAll
        res = spriteSheetBuilder.addMovieClip(mc, null, scale * @resolutionFactor)
        frames = spriteSheetBuilder._animations['temp'].frames
        framesMap = _.zipObject _.range(frames.length), frames
      else
        framesMap = {}
        framesToRender = _.uniq(_.flatten((a.frames.split(',') for a in actions)))
        for frame in framesToRender
          frame = parseInt(frame)
          f = _.bind(mc.gotoAndStop, mc, frame)
          framesMap[frame] = spriteSheetBuilder.addFrame(mc, null, scale * @resolutionFactor, f)
      
      for action in actions
        name = @renderGroupingKey(thangType, action.name, colorConfig)
        
        if action.frames
          frames = (framesMap[parseInt(frame)] for frame in action.frames.split(','))
        else
          frames = _.values(framesMap).sort()
          
        next = true
        next = action.goesTo if action.goesTo
        next = false if action.loops is false

        spriteSheetBuilder.addAnimation(name, frames, next) 
        
    containerActions = []
    for a in actionObjects
      continue unless a.container
      continue unless a.name in actionNames
      containerActions.push(a)
    
    containerGroups = _.groupBy containerActions, (action) -> action.container
    for containerName, actions of containerGroups
      container = spriteBuilder.buildContainerFromStore(containerName)
      scale = actions[0].scale or thangType.get('scale') or 1
      frame = spriteSheetBuilder.addFrame(container, null, scale * @resolutionFactor)
      for action in actions
        name = @renderGroupingKey(thangType, action.name, colorConfig)
        spriteSheetBuilder.addAnimation(name, [frame], false)      
    
  renderRasterImage: (thangType, spriteSheetBuilder) ->
    unless thangType.rasterImage
      console.error("Cannot render the WebGLLayer SpriteSheet until the raster image for <#{thangType.get('name')}> is loaded.")
    
    bm = new createjs.Bitmap(thangType.rasterImage[0])
    scale = thangType.get('scale') or 1
    frame = spriteSheetBuilder.addFrame(bm, null, scale)
    spriteSheetBuilder.addAnimation(@renderGroupingKey(thangType), [frame], false)

  setImageObjectToCocoSprite: (cocoSprite) ->
    if not cocoSprite.thangType.isFullyLoaded()
      # just give a placeholder
      sprite = new createjs.Sprite(@spriteSheet)
    
    else if cocoSprite.thangType.get('raster')
      sprite = new createjs.Sprite(@spriteSheet)
      reg = cocoSprite.getOffset 'registration'
      sprite.regX = -reg.x
      sprite.regY = -reg.y
      sprite.gotoAndStop(@renderGroupingKey(cocoSprite.thangType))
      
    else
      prefix = @renderGroupingKey(cocoSprite.thangType, null, cocoSprite.colorConfig) + '.'
      sprite = new WebGLSprite(@spriteSheet, cocoSprite.thangType, prefix)      

    sprite.sprite = cocoSprite
    sprite.layerPriority = cocoSprite.thang?.layerPriority ? cocoSprite.thangType.get 'layerPriority'
    sprite.name = cocoSprite.thang?.spriteName or cocoSprite.thangType.get 'name'
    cocoSprite.addHealthBar()
    cocoSprite.setImageObject(sprite)
    cocoSprite.update(true)
    @spriteContainer.addChild(sprite)