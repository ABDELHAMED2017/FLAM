% Five-point stencil on the unit square, Poisson equation.
%
% This example solves the Poisson equation on the unit square with Dirichlet
% boundary conditions. The system is discretized using the standard five-point
% stencil; the resulting matrix is square, real, and positive-definite.
%
% This demo does the following in order:
%
%   - compress the matrix
%   - build/factor extended sparsification
%   - check multiply error/time
%   - check solve error/time (using extended sparsification)
%   - compare CG with/without preconditioning by approximate solve

function fd_square(n,occ,rank_or_tol,symm,doiter)

  % set default parameters
  if nargin < 1 || isempty(n), n = 128; end  % number of points in one dimension
  if nargin < 2 || isempty(occ), occ = 128; end
  if nargin < 3 || isempty(rank_or_tol), rank_or_tol = 1e-9; end
  if nargin < 4 || isempty(symm), symm = 'p'; end  % positive-definite
  if nargin < 5 || isempty(doiter), doiter = 1; end  % unpreconditioned CG?

  % initialize
  [x1,x2] = ndgrid((1:n)/n); x = [x1(:) x2(:)]'; clear x1 x2  % grid points
  N = size(x,2);

  % set up sparse matrix
  h = 1/(n + 1);           % mesh width
  idx = reshape(1:N,n,n);  % index mapping to each point
  Im = idx(1:n,1:n); Jm = idx(1:n,1:n);    % interaction with middle (self)
  Sm = 4/h^2*ones(size(Im));
  Il = idx(1:n-1,1:n); Jl = idx(2:n,1:n);  % interaction with left
  Sl = -1/h^2*ones(size(Il));
  Ir = idx(2:n,1:n); Jr = idx(1:n-1,1:n);  % interaction with right
  Sr = -1/h^2*ones(size(Ir));
  Iu = idx(1:n,1:n-1); Ju = idx(1:n,2:n);  % interaction with up
  Su = -1/h^2*ones(size(Iu));
  Id = idx(1:n,2:n); Jd = idx(1:n,1:n-1);  % interaction with down
  Sd = -1/h^2*ones(size(Id));
  % combine all interactions
  I = [Im(:); Il(:); Ir(:); Iu(:); Id(:)];
  J = [Jm(:); Jl(:); Jr(:); Ju(:); Jd(:)];
  S = [Sm(:); Sl(:); Sr(:); Su(:); Sd(:)];
  A = sparse(I,J,S,N,N);
  clear idx Im Jm Sm Il Jl Sl Ir Jr Sr Iu Ju Su Id Jd Sd I J S

  % compress matrix
  Afun = @(i,j)Afun_(i,j,A);
  pxyfun = @(rc,rx,cx,slf,nbr,l,ctr)pxyfun_(rc,rx,cx,slf,nbr,l,ctr,A);
  opts = struct('symm',symm,'verb',1);
  tic; F = rskel(Afun,x,x,occ,rank_or_tol,pxyfun,opts); t = toc;
  w = whos('F'); mem = w.bytes/1e6;
  fprintf('rskel time/mem: %10.4e (s) / %6.2f (MB)\n',t,mem)

  % build extended sparsification
  tic; S = rskel_xsp(F); t = toc;
  w = whos('S'); mem = w.bytes/1e6;
  fprintf('rskel_xsp time/mem: %10.4e (s) / %6.2f (MB)\n',t,mem);

  % factor extended sparsification
  dolu = strcmpi(F.symm,'n');  % LU or LDL?
  % note: extended sparse matrix is not SPD even if original matrix is!
  if ~dolu && isoctave()
    warning('No LDL in Octave; using LU.')
    dolu = 1;
    S = S + tril(S,-1)';
  end
  FS = struct('lu',dolu);
  tic
  if dolu, [FS.L,FS.U,FS.P] = lu(A);
  else,    [FS.L,FS.D,FS.P] = ldl(A);
  end
  t = toc;
  w = whos('FS'); mem = w.bytes/1e6;
  fprintf('  factor time/mem: %10.4e (s) / %6.2f (MB)\n',t,mem)
  sv = @(x,trans)sv_(FS,x,trans);  % linear solve function

  % test accuracy using randomized power method
  X = rand(N,1);
  X = X/norm(X);

  % NORM(A - F)/NORM(A)
  tic; rskel_mv(F,X); t = toc;  % for timing
  err = snorm(N,@(x)(A*x - rskel_mv(F,x)),[],[],1);
  err = err/snorm(N,@(x)(A*x),[],[],1);
  fprintf('rskel_mv err/time: %10.4e / %10.4e (s)\n',err,t)

  % NORM(INV(A) - INV(F))/NORM(INV(A)) <= NORM(I - A*INV(F))
  tic; sv(X,'n'); t = toc;  % for timing
  err = snorm(N,@(x)(x - A*sv(x,'n')),@(x)(x - sv(A*x,'c')));
  fprintf('rskel_xsp solve err/time: %10.4e / %10.4e (s)\n',err,t)

  % run unpreconditioned CG
  B = A*X;
  iter = nan;
  if doiter, [~,~,~,iter] = pcg(@(x)(A*x),B,1e-12,128); end

  % run preconditioned CG
  tic; [Y,~,~,piter] = pcg(@(x)(A*x),B,1e-12,32,@(x)sv(x,'n')); t = toc;
  err1 = norm(X - Y)/norm(X);
  err2 = norm(B - A*Y)/norm(B);
  fprintf('cg soln/resid err, time: %10.4e / %10.4e / %10.4e (s)\n', ...
          err1,err2,t)
  fprintf('cg precon/unprecon iter: %d / %d\n',piter,iter)
end

% matrix entries
function A = Afun_(i,j,S)
  A = spget(S,i,j);
end

% proxy function
function [Kpxy,nbr] = pxyfun_(rc,rx,cx,slf,nbr,l,ctr,A)
  % only neighbor interactions -- no far field
  Kpxy = zeros(0,length(slf));
  if strcmpi(rc,'r'), Kpxy = Kpxy'; end
  % keep only neighbors with nonzero interaction
  [nbr,~] = find(A(:,slf));
  nbr = nbr(ismemb(nbr,sort(nbr)));
end

% sparse LU/LDL solve
function Y = sv_(F,X,trans)
  N = size(X,1);
  X = [X; zeros(size(F.L,1)-N,size(X,2))];
  if F.lu
    if strcmpi(trans,'n'), Y = F.U \(F.L \(F.P *X));
    else,                  Y = F.P'*(F.L'\(F.U'\X));
    end
  else
    Y = F.P*(F.L'\(F.D\(F.L\(F.P'*X))));
  end
  Y = Y(1:N,:);
end