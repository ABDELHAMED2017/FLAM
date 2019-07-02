% Underdetermined least squares on the unit square, Laplace kernel.
%
% This example solves an undetermined least squares problem arising from data
% fitting at random points in the unit square by Laplace kernel radial basis
% functions on an equispaced grid. The matrix is rectangular (short-and-fat) and
% real; we use an FMM as a fast computational reference.
%
% This demo does the following in order:
%
%   - compress the matrix
%   - check multiply error/time
%   - build/factor extended sparsification (ULS form)
%   - check pseudoinverse solve error/time
%   - compare LSQR/CG with/without initial guess from approximate solve

function uls_square(m,n,occ,p,rank_or_tol,store,doiter)

  % set default parameters
  if nargin < 1 || isempty(m), m = 8192; end  % number of row points
  if nargin < 2 || isempty(n), n = 128; end   % number of col points in one dim
  if nargin < 3 || isempty(occ), occ = 128; end
  if nargin < 4 || isempty(p), p = 64; end  % number of proxy points
  if nargin < 5 || isempty(rank_or_tol), rank_or_tol = 1e-6; end
  if nargin < 6 || isempty(store), store = 'a'; end  % FMM storage mode
  if nargin < 7 || isempty(doiter), doiter = 1; end  % naive LSQR/CG?

  % initialize
  rx = rand(2,m);                                               % row points
  [x1,x2] = ndgrid((1:n)/n); cx = [x1(:) x2(:)]'; clear x1 x2;  % col points
  M = size(rx,2);
  N = size(cx,2);
  theta = (1:p)*2*pi/p; proxy = 1.5*[cos(theta); sin(theta)];  % proxy points
  % reference proxy points are for unit box [-1, 1]^2

  % compress matrix using RSKEL
  Afun = @(i,j)Afun_(i,j,rx,cx);
  pxyfun = @(rc,rx,cx,slf,nbr,l,ctr)pxyfun_(rc,rx,cx,slf,nbr,l,ctr,proxy);
  opts = struct('verb',1);
  tic; F = rskel(Afun,rx,cx,occ,rank_or_tol,pxyfun,opts); t = toc;
  w = whos('F'); mem = w.bytes/1e6;
  fprintf('rskel time/mem: %10.4e (s) / %6.2f (MB)\n',t,mem)

  % compress matrix using IFMM
  opts = struct('store',store);
  rank_or_tol = max(rank_or_tol*1e-2,1e-15);  % higher accuracy for reference
  tic; G = ifmm(Afun,rx,cx,occ,rank_or_tol,pxyfun,opts); t = toc;
  w = whos('G'); mem = w.bytes/1e6;
  fprintf('ifmm time/mem: %10.4e (s) / %6.2f (MB)\n',t,mem)

  % test accuracy using randomized power method
  X = rand(N,1);
  X = X/norm(X);

  % NORM(A - F)/NORM(A)
  tic; rskel_mv(F,X); t = toc;  % for timing
  err = snorm(N,@(x)(ifmm_mv(G,x,Afun,'n') - rskel_mv(F,x,'n')), ...
                @(x)(ifmm_mv(G,x,Afun,'c') - rskel_mv(F,x,'c')));
  err = err/snorm(N,@(x)(ifmm_mv(G,x,Afun,'n')),@(x)(ifmm_mv(G,x,Afun,'c')));
  fprintf('rskel_mv err/time: %10.4e / %10.4e (s)\n',err,t)
  tic; ifmm_mv(G,X,Afun); t = toc;
  fprintf('ifmm_mv time: %10.4e (s)\n',t)

  % build extended sparsification
  tau = eps^(-1/3);
  tic
  A = rskel_xsp(F);
  A = [tau*A; speye(N) sparse(N,size(A,2)-N)];
  t = toc;
  w = whos('A'); mem = w.bytes/1e6;
  fprintf('rskel_xsp:\n')
  fprintf('  build time/mem: %10.4e (s) / %6.2f (MB)\n',t,mem);

  % factor extended sparsification
  tic; R = qr(A,0); t = toc;
  w = whos('R'); mem = w.bytes/1e6;
  fprintf('  qr time/mem: %10.4e (s) / %6.2f (MB)\n',t,mem)
  nc = size(A,1) - N;         % number of constraints
  ls = @(X)ls_(A,R,X,N,tau);  % least squares solve function

  % test pseudoinverse apply accuracy
  B = ifmm_mv(G,X,Afun);  % random right-hand side in range
  C = [B; zeros(nc-M,1)];
  tic; [Y,cres,niter] = ls(C); t = toc;
  err1 = norm(X - Y)/norm(X);
  err2 = norm(B - ifmm_mv(G,Y,Afun))/norm(B);
  fprintf('ls:\n')
  fprintf('  soln/resid err/time: %10.4e / %10.4e / %10.4e (s)\n',err1,err2,t)
  fprintf('  constraint resid/iter/soln norm: %10.4e / %d / %10.4e\n', ...
          norm(cres),niter,norm(Y))

  iter = nan;
  if ~isoctave()
    mv = @(x,trans)mv_lsqr(G,x,trans,Afun);

    % run LSQR
    if doiter, [~,~,~,iter] = lsqr(mv,B,1e-6,128); end

    % run LSQR with initial guess from pseudoinverse
    tic; [Z,~,~,piter] = lsqr(mv,B,1e-6,32,[],[],Y); t = toc;
    fprintf('lsqr:\n')
  else
    warning('No LSQR in Octave.')

    C = ifmm_mv(G,B,Afun,'c');
    mv = @(x)mv_cg(G,x,Afun);

    % run CG (on normal equations)
    if doiter, [~,~,~,iter] = pcg(mv,C,1e-6,128); end

    % run CG with initial guess from pseudoinverse
    tic; [Z,~,~,piter] = pcg(mv,C,1e-6,32,[],[],Y); t = toc;
    fprintf('cg:\n')
  end
  err1 = norm(X - Z)/norm(X);
  err2 = norm(B - ifmm_mv(G,Z,Afun))/norm(B);
  fprintf('  soln/resid err/time: %10.4e / %10.4e / %10.4e (s)\n',err1,err2,t)
  fprintf('  init/uninit iter: %d / %d\n',piter,iter)
end

% kernel function
function K = Kfun(x,y)
  dx = bsxfun(@minus,x(1,:)',y(1,:));
  dy = bsxfun(@minus,x(2,:)',y(2,:));
  K = -1/(2*pi)*log(sqrt(dx.^2 + dy.^2));
end

% matrix entries
function A = Afun_(i,j,rx,cx)
  A = Kfun(rx(:,i),cx(:,j));
end

% proxy function
function [Kpxy,nbr] = pxyfun_(rc,rx,cx,slf,nbr,l,ctr,proxy)
  pxy = bsxfun(@plus,proxy*l,ctr');  % scale and translate reference points
  if strcmpi(rc,'r')
    Kpxy = Kfun(rx(:,slf),pxy);
    dx = cx(1,nbr) - ctr(1);
    dy = cx(2,nbr) - ctr(2);
  else
    Kpxy = Kfun(pxy,cx(:,slf));
    dx = rx(1,nbr) - ctr(1);
    dy = rx(2,nbr) - ctr(2);
  end
  % proxy points form circle of scaled radius 1.5 around current box
  % keep among neighbors only those within circle
  dist = sqrt(dx.^2 + dy.^2);
  nbr = nbr(dist/l < 1.5);
end

% weighted least squares solve
function x = lsfun(A,R,b)
  x = R\(R'\(A'*b));              % normal equation solve with one step of
  x = x + R\(R'\(A'*(b - A*x)));  % iterative refinement for accuracy
end

% equality-constrained least squares solve
function [Y,cres,niter] = ls_(A,R,X,N,tau)
  p = size(X,2);
  nc = size(A,1) - N;  % number of constraints
  % deferred correction for iterated weighted least squares
  [Y,cres,niter] = lsedc(@(b)lsfun(A,R,b),A(nc+1:end,:),zeros(N,p), ...
                         A(1:nc,:)/tau,X,tau);
  Y = Y(1:N,:);
end

% matrix multiply for LSQR
function y = mv_lsqr(F,x,trans,Afun)
  if     strcmpi(trans,'notransp'), y = ifmm_mv(F,x,Afun,'n');
  elseif strcmpi(trans,  'transp'), y = ifmm_mv(F,x,Afun,'c');
  end
end

% matrix multiply for CG
function y = mv_cg(F,x,Afun)
  y = ifmm_mv(F,ifmm_mv(F,x,Afun,'n'),Afun,'c');
end