function res = vl_simplenn(net, x, dzdy, res, varargin)
% VL_SIMPLENN  Evaluates a simple CNN
%   RES = VL_SIMPLENN(NET, X) evaluates the convnet NET on data X.
%   RES = VL_SIMPLENN(NET, X, DZDY) evaluates the convnent NET and its
%   derivative on data X and output derivative DZDY.
%
%   The network has a simple (linear) topology, i.e. the computational
%   blocks are arranged in a sequence of layers. Please note that
%   there is no need to use this wrapper, which is provided for
%   convenience. Instead, the individual CNN computational blocks can
%   be evaluated directly, making it possible to create significantly
%   more complex topologies, and in general allowing greater
%   flexibility.
%
%   The NET structure contains two fields:
%
%   - net.layers: the CNN layers.
%   - net.normalization: information on how to normalize input data.
%
%   The network expects the data X to be already normalized. This
%   usually involves rescaling the input image(s) and subtracting a
%   mean.
%
%   RES is a structure array with one element per network layer plus
%   one representing the input. So RES(1) refers to the zeroth-layer
%   (input), RES(2) refers to the first layer, etc. Each entry has
%   fields:
%
%   - res(i+1).x: the output of layer i. Hence res(1).x is the network
%     input.
%
%   - res(i+1).aux: auxiliary output data of layer i. For example,
%     dropout uses this field to store the dropout mask.
%
%   - res(i+1).dzdx: the derivative of the network output relative to
%     variable res(i+1).x, i.e. the output of layer i. In particular
%     res(1).dzdx is the derivative of the network output with respect
%     to the network input.
%
%   - res(i+1).dzdw: the derivative of the network output relative to
%     the parameters of layer i. It can be a cell array for multiple
%     parameters.
%
%   net.layers is a cell array of network layers. The following
%   layers, encapsulating corresponding functions in the toolbox, are
%   supported:
%
%   Convolutional layer::
%     The convolutional layer wraps VL_NNCONV(). It has fields:
%
%     - layer.type = 'conv'
%     - layer.weights = {filters, biases}
%     - layer.stride: the sampling stride (usually 1).
%     - layer.padding: the padding (usually 0).
%
%   Max pooling layer::
%     The max pooling layer wraps VL_NNPOOL(). It has fields:
%
%     - layer.type = 'pool'
%     - layer.method: pooling method ('max' or 'avg').
%     - layer.pool: the pooling size.
%     - layer.stride: the sampling stride (usually 1).
%     - layer.padding: the padding (usually 0).
%
%   Normalization layer::
%     The normalization layer wraps VL_NNNORMALIZE(). It has fields
%
%     - layer.type = 'normalize'
%     - layer.param: the normalization parameters.
%
%   Spatial normalization layer:
%     This is similar to the layer above, but wraps VL_NNSPNORM():
%
%     - layer.type = 'spnorm'
%     - layer.param: the normalization parameters.
%
%   Batch normalization layer:
%     This layer wraps VL_NNBNORM(). It has fields:
%
%     - layer.type = 'bnorm'
%     - layer.weights = {multipliers, biases}.
%
%   ReLU and Sigmoid layers::
%     The ReLU layer wraps VL_NNRELU(). It has fields:
%
%     - layer.type = 'relu'
%
%     The sigmoid layer is the same, but for the sigmoid function, with
%     `relu` replaced by `sigmoid`.
%
%   Dropout layer::
%     The dropout layer wraps VL_NNDROPOUT(). It has fields:
%
%     - layer.type = 'dropout'
%     - layer.rate: the dropout rate.
%
%   Softmax layer::
%     The softmax layer wraps VL_NNSOFTMAX(). It has fields
%
%     - layer.type = 'softmax'
%
%   Log-loss layer::
%     The log-loss layer wraps VL_NNLOSS(). It has fields:
%
%     - layer.type = 'loss'
%     - layer.class: the ground-truth class.
%
%   Softmax-log-loss layer::
%     The softmax-log-loss layer wraps VL_NNSOFTMAXLOSS(). It has
%     fields:
%
%     - layer.type = 'softmaxloss'
%     - layer.class: the ground-truth class.
%
%   P-dist layer:
%     The pdist layer wraps VL_NNPDIST(). It has fields:
%
%     - layer.type = 'pdist'
%     - layer.p = P parameter of the P-distance
%     - layer.noRoot = whether to raise the distance to the P-th power
%     - layer.epsilon = regularization parameter for the derivatives
%
%   Custom layer::
%     This can be used to specify custom layers.
%
%     - layer.type = 'custom'
%     - layer.forward: a function handle computing the block.
%     - layer.backward: a function handle computing the block derivative.
%
%     The first function is called as res(i+1) = forward(layer, res(i), res(i+1))
%     where res() is the struct array specified before. The second function is
%     called as res(i) = backward(layer, res(i), res(i+1)). Note that the
%     `layer` structure can contain additional fields if needed.

% Copyright (C) 2014 Andrea Vedaldi.
% All rights reserved.
%
% This file is part of the VLFeat library and is made available under
% the terms of the BSD license (see the COPYING file).

% normalize if needed
if isfield(net, 'normalization') && isfield(net.normalization, 'averageImage')
    for i = 1:size(x,4)
        x_i = x(:,:,:,i);
        x_i = cat( 3, x_i(:,:,1)-net.normalization.averageImage(1), ...
                x_i(:,:,2)-net.normalization.averageImage(2), ...
                x_i(:,:,3)-net.normalization.averageImage(3) ); 
        x(:,:,:,i) = x_i;
    end
end

opts.res = [] ;
opts.conserveMemory = false ;
opts.sync = false ;
opts.disableDropout = false ;
opts.freezeDropout = false ;
opts.accumulate = false;
opts.backPropDepth = +inf ;

opts = vl_argparse(opts, varargin);

n = numel(net.layers) ;

if (nargin <= 2) || isempty(dzdy)
  doder = false ;
else
  doder = true ;
end

gpuMode = isa(x, 'gpuArray') ;

if nargin <= 3 || isempty(res)
  res = struct(...
    'x', cell(1,n+1), ...
    'dzdx', cell(1,n+1), ...
    'dzdw', cell(1,n+1), ...
    'aux', cell(1,n+1), ...
    'time', num2cell(zeros(1,n+1)), ...
    'backwardTime', num2cell(zeros(1,n+1))) ;
  res(1).x = x ;
end

for i=1:n
  l = net.layers{i} ;
  res(i).time = tic ;
  if ~isempty( res(i+1).x )
      continue;
  end
  switch l.type
    case 'conv'
      if isfield(l, 'weights')
        res(i+1).x = vl_nnconv(res(i).x, l.weights{1}, l.weights{2}, 'pad', l.pad, 'stride', l.stride) ;
      else
        res(i+1).x = vl_nnconv(res(i).x, l.filters, l.biases, 'pad', l.pad, 'stride', l.stride) ;
      end
    case 'pool'
      res(i+1).x = vl_nnpool(res(i).x, l.pool, 'pad', l.pad, 'stride', l.stride, 'method', l.method) ;
    case 'normalize'
      res(i+1).x = vl_nnnormalize(res(i).x, l.param) ;
    case 'softmax'
      res(i+1).x = vl_nnsoftmax(res(i).x) ;
    case 'loss'
      res(i+1).x = vl_nnloss(res(i).x, l.class) ;
    case 'softmaxloss'
      res(i+1).x = vl_nnsoftmaxloss(res(i).x, l.class) ;
    case 'relu'
      res(i+1).x = vl_nnrelu(res(i).x) ;
    case 'sigmoid'
      res(i+1).x = vl_nnsigmoid(res(i).x) ;
    case 'noffset'
      res(i+1).x = vl_nnnoffset(res(i).x, l.param) ;
    case 'spnorm'
      res(i+1).x = vl_nnspnorm(res(i).x, l.param) ;
    case 'dropout'
      if opts.disableDropout
        res(i+1).x = res(i).x ;
      elseif opts.freezeDropout
        [res(i+1).x, res(i+1).aux] = vl_nndropout(res(i).x, 'rate', l.rate, 'mask', res(i+1).aux) ;
      else
        [res(i+1).x, res(i+1).aux] = vl_nndropout(res(i).x, 'rate', l.rate) ;
      end
    case 'bnorm'
      if isfield(l, 'weights') && isfield(l, 'my_moments') % added by Mahmood
        res(i+1).x = vl_nnbnorm(res(i).x, l.weights{1}, l.weights{2}, 'Moments', l.my_moments ) ;
      elseif isfield(l, 'weights')
        res(i+1).x = vl_nnbnorm(res(i).x, l.weights{1}, l.weights{2}) ;
      else
        res(i+1).x = vl_nnbnorm(res(i).x, l.filters, l.biases) ;
      end
    case 'pdist'
      res(i+1) = vl_nnpdist(res(i).x, l.p, 'noRoot', l.noRoot, 'epsilon', l.epsilon) ;
	case 'mseloss' % added by Mahmood
      res(i+1).x = vl_nnmseloss(res(i).x, l.class) ;
	case 'dot'
      res(i+1).x = vl_nndot(res(i).x, l.weights{1});
    case 'bnorm_custom'
      res(i+1).x = vl_nnbnorm_custom(res(i).x, l.weights{1}, l.weights{2}, l.mu, l.v) ;
    case 'reshape_theano'
      res(i+1).x = vl_nnreshape_like_theano(res(i).x, l.new_shape) ;
    case 'reshape' % for backward compatibility
      res(i+1).x = vl_nnreshape_like_theano(res(i).x, l.new_shape) ;
    case 'deconv'
      res(i+1).x = vl_nndeconv(res(i).x, l.weights{1}, l.weights{2}, l.pad, l.stride, l.mode) ;
    case 'tanh'
      res(i+1).x = vl_nntanh(res(i).x) ;
    case 'myconv'
      res(i+1).x = vl_nnmyconv(res(i).x, l.weights{1}, l.weights{2}, l.pad, l.stride) ;
    case 'lrelu'
      res(i+1).x = vl_nnlrelu(res(i).x);
    case 'bce'
      res(i+1).x = vl_nnbce(res(i).x, l.p);
    case 'mulconst' % implementated in '../openface/layers/'
      res(i+1).x = vl_nnmulconst(res(i).x, l.constant);
    case 'cwloss' % Carlini and Wagner loss
      res(i+1).x = carlini_wagner_loss(res(i).x, l.class);
	case 'our_loss' % Our loss function
      res(i+1).x = our_loss(res(i).x, l.class);
    case 'custom'
      res(i+1) = l.forward(l, res(i), res(i+1)) ;
    otherwise
      error('Unknown layer type %s', l.type) ;
  end
  % optionally forget intermediate results
  forget = opts.conserveMemory ;
  forget = forget & (~doder || strcmp(l.type, 'relu')) ;
  forget = forget & ~(strcmp(l.type, 'loss') || strcmp(l.type, 'softmaxloss')) ;
  forget = forget & (~isfield(l, 'rememberOutput') || ~l.rememberOutput) ;
  if forget
    res(i).x = [] ;
  end
  if gpuMode & opts.sync
    % This should make things slower, but on MATLAB 2014a it is necessary
    % for any decent performance.
    wait(gpuDevice) ;
  end
  res(i).time = toc(res(i).time) ;
end

if doder
  res(n+1).dzdx = dzdy ;
  for i=n:-1:max(1, n-opts.backPropDepth+1)
    l = net.layers{i} ;
    res(i).backwardTime = tic ;
    switch l.type
      case 'conv'
        if ~opts.accumulate
          if isfield(l, 'weights')
            [res(i).dzdx, res(i).dzdw{1}, res(i).dzdw{2}] = ...
                vl_nnconv(res(i).x, l.weights{1}, l.weights{2}, ...
                          res(i+1).dzdx, ...
                          'pad', l.pad, 'stride', l.stride) ;
          else
            % Legacy code: will go
            [res(i).dzdx, res(i).dzdw{1}, res(i).dzdw{2}] = ...
                vl_nnconv(res(i).x, l.filters, l.biases, ...
                          res(i+1).dzdx, ...
                          'pad', l.pad, 'stride', l.stride) ;
          end
        else
          dzdw = cell(1,2) ;
          if isfield(l, 'weights')
            [res(i).dzdx, dzdw{1}, dzdw{2}] = ...
                vl_nnconv(res(i).x, l.weights{1}, l.weights{2}, ...
                          res(i+1).dzdx, ...
                          'pad', l.pad, 'stride', l.stride) ;
          else
            % Legacy code: will go
            [res(i).dzdx, dzdw{1}, dzdw{2}] = ...
                vl_nnconv(res(i).x, l.filters, l.biases, ...
                          res(i+1).dzdx, ...
                          'pad', l.pad, 'stride', l.stride) ;
          end
          for j=1:2
            res(i).dzdw{j} = res(i).dzdw{j} + dzdw{j} ;
          end
          clear dzdw ;
        end

      case 'pool'
        res(i).dzdx = vl_nnpool(res(i).x, l.pool, res(i+1).dzdx, ...
          'pad', l.pad, 'stride', l.stride, 'method', l.method) ;
      case 'normalize'
        res(i).dzdx = vl_nnnormalize(res(i).x, l.param, res(i+1).dzdx) ;
      case 'softmax'
        res(i).dzdx = vl_nnsoftmax(res(i).x, res(i+1).dzdx) ;
      case 'loss'
        res(i).dzdx = vl_nnloss(res(i).x, l.class, res(i+1).dzdx) ;
      case 'softmaxloss'
        res(i).dzdx = vl_nnsoftmaxloss(res(i).x, l.class, res(i+1).dzdx) ;
      case 'relu'
        if ~isempty(res(i).x)
          res(i).dzdx = vl_nnrelu(res(i).x, res(i+1).dzdx) ;
        else
          % if res(i).x is empty, it has been optimized away, so we use this
          % hack (which works only for ReLU):
          res(i).dzdx = vl_nnrelu(res(i+1).x, res(i+1).dzdx) ;
        end
      case 'sigmoid'
        res(i).dzdx = vl_nnsigmoid(res(i).x, res(i+1).dzdx) ;
      case 'noffset'
        res(i).dzdx = vl_nnnoffset(res(i).x, l.param, res(i+1).dzdx) ;
      case 'spnorm'
        res(i).dzdx = vl_nnspnorm(res(i).x, l.param, res(i+1).dzdx) ;
      case 'dropout'
        if opts.disableDropout
          res(i).dzdx = res(i+1).dzdx ;
        else
          res(i).dzdx = vl_nndropout(res(i).x, res(i+1).dzdx, 'mask', res(i+1).aux) ;
        end
      case 'bnorm'
        if isfield(l, 'weights') && isfield(l, 'my_moments') % added by Mahmood
            [res(i).dzdx, res(i).dzdw{1}, res(i).dzdw{2}] = ...
                vl_nnbnorm(res(i).x, l.weights{1}, l.weights{2}, ...
                           res(i+1).dzdx, 'Moments', l.my_moments) ; 
        elseif ~opts.accumulate
          if isfield(l, 'weights')
            [res(i).dzdx, res(i).dzdw{1}, res(i).dzdw{2}] = ...
                vl_nnbnorm(res(i).x, l.weights{1}, l.weights{2}, ...
                           res(i+1).dzdx) ;
          else
            [res(i).dzdx, res(i).dzdw{1}, res(i).dzdw{2}] = ...
                vl_nnbnorm(res(i).x, l.filters, l.biases, ...
                           res(i+1).dzdx) ;
          end
        else
          dzdw = cell(1,2) ;
          if isfield(l, 'weights') && isfield(l, 'my_moments') % added by Mahmood
            [res(i).dzdx, dzdw{1}, dzdw{2}] = ...
                vl_nnbnorm(res(i).x, l.weights{1}, l.weights{2}, ...
                           res(i+1).dzdx, 'Moments', l.my_moments) ; 
          elseif isfield(l, 'weights')
            [res(i).dzdx, dzdw{1}, dzdw{2}] = ...
                vl_nnbnorm(res(i).x, l.weights{1}, l.weights{2}, ...
                           res(i+1).dzdx) ;
          else
            [res(i).dzdx, dzdw{1}, dzdw{2}] = ...
                vl_nnbnorm(res(i).x, l.filters, l.biases, ...
                           res(i+1).dzdx) ;
          end
          for j=1:2
            res(i).dzdw{j} = res(i).dzdw{j} + dzdw{j} ;
          end
          clear dzdw ;
        end
      case 'pdist'
        res(i).dzdx = vl_nnpdist(res(i).x, l.p, res(i+1).dzdx, ...
                                 'noRoot', l.noRoot, 'epsilon', l.epsilon) ;
      case 'mseloss' % added by Mahmood
        res(i).dzdx = vl_nnmseloss(res(i).x, l.class, res(i+1).dzdx);
      case 'dot'
        [res(i).dzdx, res(i).dzdw{1}] = vl_nndot(res(i).x, l.weights{1}, res(i+1).dzdx);
      case 'bnorm_custom'
        [res(i).dzdx, res(i).dzdw{1}, res(i).dzdw{2}] = ...
                vl_nnbnorm_custom(res(i).x, l.weights{1}, l.weights{2}, l.mu, l.v, res(i+1).dzdx) ;
      case 'reshape_theano'
        res(i).dzdx = vl_nnreshape_like_theano(res(i).x, l.new_shape, res(i+1).dzdx) ;
      case 'reshape' % for backward compatibility
        res(i).dzdx = vl_nnreshape_like_theano(res(i).x, l.new_shape, res(i+1).dzdx) ;
      case 'deconv'
        [res(i).dzdx, res(i).dzdw{1}, res(i).dzdw{2}] = ...
                vl_nndeconv(res(i).x, l.weights{1}, l.weights{2}, l.pad, l.stride, l.mode, res(i+1).dzdx) ;
      case 'tanh'
        res(i).dzdx = vl_nntanh(res(i).x, res(i+1).dzdx) ;
      case 'myconv'
        [res(i).dzdx, res(i).dzdw{1}, res(i).dzdw{2}] = ...
                vl_nnmyconv(res(i).x, l.weights{1}, l.weights{2}, l.pad, l.stride, res(i+1).dzdx) ;
      case 'lrelu'
        res(i).dzdx = vl_nnlrelu(res(i).x, res(i+1).dzdx);
      case 'bce'
        res(i).dzdx = vl_nnbce(res(i).x, l.p, res(i+1).dzdx);
      case 'mulconst'
        res(i).dzdx = vl_nnmulconst(res(i).x, res(i+1).dzdx);
      case 'cwloss' % Carlini and Wagner loss
        res(i).dzdx = carlini_wagner_loss(res(i).x, l.class, res(i+1).dzdx);
      case 'our_loss' % Our loss function
        res(i).dzdx = our_loss(res(i).x, l.class, res(i+1).dzdx);
      case 'custom'
        res(i) = l.backward(l, res(i), res(i+1)) ;
    end
    if opts.conserveMemory
      res(i+1).dzdx = [] ;
    end
    if gpuMode & opts.sync
      wait(gpuDevice) ;
    end
    res(i).backwardTime = toc(res(i).backwardTime) ;
  end
end
