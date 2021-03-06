% Five-point stencil on the unit square, variable-coefficient Poisson equation,
% Dirichlet boundary conditions.
%
% This is basically the same as FD_SQUARE1 but with a variable quantized high-
% contrast random coefficient field that makes the problem especially ill-
% conditioned.

function fd_square2(n,occ,rank_or_tol,skip,symm,doiter,diagmode)

  % set default parameters
  if nargin < 1 || isempty(n), n = 128; end  % number of points + 1 in each dim
  if nargin < 2 || isempty(occ), occ = 8; end
  if nargin < 3 || isempty(rank_or_tol), rank_or_tol = 1e-9; end
  if nargin < 4 || isempty(skip), skip = 2; end
  if nargin < 5 || isempty(symm), symm = 'p'; end  % positive definite
  if nargin < 6 || isempty(doiter), doiter = 1; end  % unpreconditioned CG?
  if nargin < 7 || isempty(diagmode), diagmode = 0; end  % diag extraction mode:
  % 0 - skip; 1 - matrix unfolding; 2 - sparse apply/solves

  % initialize
  N = (n - 1)^2;  % total number of grid points

  % set up conductivity field
  a = zeros(n+1,n+1);
  A = rand(n-1,n-1);                   % random field
  A = fft2(A,2*n-3,2*n-3);
  [X,Y] = ndgrid(0:n-2);
  C = normpdf(X,0,4).*normpdf(Y,0,4);  % Gaussian smoothing over 4 grid points
  B = zeros(2*n-3,2*n-3);
  B(1:n-1,1:n-1) = C;
  B(1:n-1,n:end) = C( :   ,2:n-1);
  B(n:end,1:n-1) = C(2:n-1, :   );
  B(n:end,n:end) = C(2:n-1,2:n-1);
  B(:,n:end) = flipdim(B(:,n:end),2);
  B(n:end,:) = flipdim(B(n:end,:),1);
  B = fft2(B);
  A = ifft2(A.*B);                     % convolution in Fourier domain
  A = A(1:n-1,1:n-1);
  idx = A > median(A(:));
  A( idx) = 1e+2;                      % set upper 50% to something large
  A(~idx) = 1e-2;                      % set lower 50% to something small
  a(2:n,2:n) = A;
  clear X Y A B C

  % set up sparse matrix
  idx = zeros(n+1,n+1);  % index mapping to each point, including "ghost" points
  idx(2:n,2:n) = reshape(1:N,n-1,n-1);
  mid = 2:n;    % "middle" indices -- interaction with self
  lft = 1:n-1;  % "left"   indices -- interaction with one below
  rgt = 3:n+1;  % "right"  indices -- interaction with one above
  I = idx(mid,mid);
  % interactions with ...
  Jl = idx(lft,mid); Sl = -0.5*(a(lft,mid) + a(mid,mid));  % ... left
  Jr = idx(rgt,mid); Sr = -0.5*(a(rgt,mid) + a(mid,mid));  % ... right
  Ju = idx(mid,lft); Su = -0.5*(a(mid,lft) + a(mid,mid));  % ... up
  Jd = idx(mid,rgt); Sd = -0.5*(a(mid,rgt) + a(mid,mid));  % ... down
  Jm = idx(mid,mid); Sm = -(Sl + Sr + Su + Sd);            % ... middle (self)
  % combine all interactions
  I = [ I(:);  I(:);  I(:);  I(:);  I(:)];
  J = [Jl(:); Jr(:); Ju(:); Jd(:); Jm(:)];
  S = [Sl(:); Sr(:); Su(:); Sd(:); Sm(:)];
  % remove ghost interactions
  idx = find(J > 0); I = I(idx); J = J(idx); S = S(idx);
  A = sparse(I,J,S,N,N);
  clear idx Jl Sl Jr Sr Ju Su Jd Sd Jm Sm I J S

  % factor matrix
  opts = struct('skip',skip,'symm',symm,'verb',1);
  tic; F = hifde2(A,n,occ,rank_or_tol,opts); t = toc;
  w = whos('F'); mem = w.bytes/1e6;
  fprintf('hifde2 time/mem: %10.4e (s) / %6.2f (MB)\n',t,mem)

  % test accuracy using randomized power method
  X = rand(N,1);
  X = X/norm(X);

  % NORM(A - F)/NORM(A)
  tic; hifde_mv(F,X); t = toc;  % for timing
  err = snorm(N,@(x)(A*x - hifde_mv(F,x)),[],[],1);
  err = err/snorm(N,@(x)(A*x),[],[],1);
  fprintf('hifde_mv: %10.4e / %10.4e (s)\n',err,t)

  % NORM(INV(A) - INV(F))/NORM(INV(A)) <= NORM(I - A*INV(F))
  tic; hifde_sv(F,X); t = toc;  % for timing
  err = snorm(N,@(x)(x - A*hifde_sv(F,x)),@(x)(x - hifde_sv(F,A*x,'c')));
  fprintf('hifde_sv: %10.4e / %10.4e (s)\n',err,t)

  % test Cholesky accuracy -- error is w.r.t. compressed apply/solve
  if strcmpi(symm,'p')
    % NORM(F - C*C')/NORM(F)
    tic; hifde_cholmv(F,X); t = toc;  % for timing
    err = snorm(N,@(x)(hifde_mv(F,x) ...
                     - hifde_cholmv(F,hifde_cholmv(F,x,'c'))),[],[],1);
    err = err/snorm(N,@(x)hifde_mv(F,x),[],[],1);
    fprintf('hifde_cholmv: %10.4e / %10.4e (s)\n',err,t)

    % NORM(INV(F) - INV(C')*INV(C))/NORM(INV(F))
    tic; hifde_cholsv(F,X); t = toc;  % for timing
    err = snorm(N,@(x)(hifde_sv(F,x) ...
                     - hifde_cholsv(F,hifde_cholsv(F,x),'c')),[],[],1);
    err = err/snorm(N,@(x)hifde_sv(F,x),[],[],1);
    fprintf('hifde_cholsv: %10.4e / %10.4e (s)\n',err,t)
  end

  % run unpreconditioned CG
  B = A*X;
  iter = nan;
  if doiter, [~,~,~,iter] = pcg(@(x)(A*x),B,1e-12,128); end

  % run preconditioned CG
  tic; [Y,~,~,piter] = pcg(@(x)(A*x),B,1e-12,32,@(x)hifde_sv(F,x)); t = toc;
  err1 = norm(X - Y)/norm(X);
  err2 = norm(B - A*Y)/norm(B);
  fprintf('cg:\n')
  fprintf('  soln/resid err/time: %10.4e / %10.4e / %10.4e (s)\n', ...
          err1,err2,t)
  fprintf('  precon/unprecon iter: %d / %d\n',piter,iter)

  % compute log-determinant
  tic
  ld = hifde_logdet(F);
  t = toc;
  fprintf('hifde_logdet: %22.16e / %10.4e (s)\n',ld,t)

  if diagmode > 0
    % prepare for diagonal extraction
    opts = struct('verb',1);
    m = min(N,128);  % number of entries to check against
    r = randperm(N); r = r(1:m);
    % reference comparison from compressed solve against coordinate vectors
    X = zeros(N,m);
    for i = 1:m, X(r(i),i) = 1; end
    E = zeros(m,1);  % solution storage
    if diagmode == 1, fprintf('hifde_diag:\n')
    else,             fprintf('hifde_spdiag:\n')
    end

    % extract diagonal
    tic;
    if diagmode == 1, D = hifde_diag(F,0,opts);
    else,             D = hifde_spdiag(F);
    end
    t = toc;
    Y = hifde_mv(F,X);
    for i = 1:m, E(i) = Y(r(i),i); end
    err = norm(D(r) - E)/norm(E);
    fprintf('  fwd: %10.4e / %10.4e (s)\n',err,t)

    % extract diagonal of inverse
    tic;
    if diagmode == 1, D = hifde_diag(F,1,opts);
    else,             D = hifde_spdiag(F,1);
    end
    t = toc;
    Y = hifde_sv(F,X);
    for i = 1:m, E(i) = Y(r(i),i); end
    err = norm(D(r) - E)/norm(E);
    fprintf('  inv: %10.4e / %10.4e (s)\n',err,t)
  end
end

% Gaussian PDF -- in case statistics toolbox not available
function y = normpdf(x,mu,sigma)
  y = exp(-0.5*((x - mu)./sigma).^2)./(sqrt(2*pi).*sigma);
end