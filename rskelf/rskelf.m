% RSKELF  Recursive skeletonization factorization.
%
%    The recursive skeletonization factorization approximates a hierarchically
%    rank-structured matrix A as a generalized LDU decomposition A = L*D*U,
%    where L and U are multilevel products of sparse unit triangular matrices
%    (both upper and lower), and D is block diagonal. In the symmetric or
%    positive definite case, this naturally becomes a generalized LDL or
%    Cholesky decomposition, respectively.
%
%    The matrix A must be square with full-rank diagonal blocks. This
%    representation facilitates fast multiplication, inversion, determinant
%    computation, and selected inversion, among other operations.
%
%    Each row/column of A is associated with a point, with identical row/column
%    indices corresponding to the same point. The induced point geometry exposes
%    the required matrix rank structure. In typical operation, only the near-
%    field (near-diagonal blocks) is explicitly evaluated; the far-field is
%    captured by a user-supplied "proxy" function. To avoid excessive storage,
%    the matrix should be given as a function handle implementing the usual
%    submatrix access interface.
%
%    This algorithm can be viewed as a dense counterpart to the multifrontal
%    factorization for sparse matrices, where the ID is used to introduce
%    sparsity at each level.
%
%    Typical complexity for N = SIZE(A,1) = SIZE(A,2): O(N) in 1D and
%    O(N^(3*(1 - 1/D))) in D dimensions.
%
%    F = RSKELF(A,X,OCC,RANK_OR_TOL) produces a factorization F of the matrix A
%    acting on the points X using tree occupancy parameter OCC and local
%    precision parameter RANK_OR_TOL. See HYPOCT and ID for details. Since no
%    proxy function is supplied, this simply performs a naive compression of all
%    off-diagonal blocks.
%
%    F = RSKELF(A,X,OCC,RANK_OR_TOL,PXYFUN) accelerates the compression using
%    the proxy function PXYFUN to capture the far field (both incoming and
%    outgoing). This is a function of the form
%
%      [KPXY,NBR] = PXYFUN(X,SLF,NBR,L,CTR)
%
%    that is called for every block, where
%
%      - KPXY: interaction matrix against artificial proxy points
%      - NBR:  block neighbor point indices (can be modified)
%      - X:    input points
%      - SLF:  block point indices
%      - L:    block node size
%      - CTR:  block node center
%
%    The relevant arguments will be passed in by the algorithm; the user is
%    responsible for handling them. See the examples for further details. If
%    PXYFUN is not provided or empty (default), then the code uses the naive
%    global compression scheme.
%
%    F = RSKELF(A,X,OCC,RANK_OR_TOL,PXYFUN,OPTS) also passes various options to
%    the algorithm. Valid options include:
%
%      - LVLMAX: maximum tree depth (default: LVLMAX = Inf). See HYPOCT.
%
%      - EXT: set the root node extent to [EXT(D,1) EXT(D,2)] along dimension D.
%             If EXT is empty (default), then the root extent is calculated from
%             the data. See HYPOCT.
%
%      - SYMM: assume that the matrix is unsymmetric if SYMM = 'N', (complex-)
%              symmetric if SYMM = 'S', Hermitian if SYMM = 'H', and Hermitian
%              positive definite if SYMM = 'P' (default: SYMM = 'N'). If
%              SYMM = 'N' or 'S', then local factors are computed using the LU
%              decomposition; if SYMM = 'H', the LDL decomposition; and if
%              SYMM = 'P', the Cholesky decomposition. Symmetry can reduce the
%              computation time by about a factor of two.
%
%      - VERB: display status info if VERB = 1 (default: VERB = 0). This prints
%              to screen a table tracking compression statistics through level.
%              Special levels: 'T', tree sorting.
%
%    Primary references:
%
%      K.L. Ho, L. Ying. Hierarchical interpolative factorization for elliptic
%        operators: integral equations. Comm. Pure Appl. Math. 69 (7):
%        1314-1353, 2016.
%
%    Other references:
%
%      S. Chandrasekaran, M. Gu, T. Pals. A fast ULV decomposition solver for
%        hierarchically semiseparable representations. SIAM J. Matrix Anal.
%        Appl. 28 (3): 603-622, 2006.
%
%      J. Xia, S. Chandrasekaran, M. Gu, X.S. Li. Fast algorithms for
%        hierarchically semiseparable matrices. Numer. Linear Algebra Appl. 17
%        (6): 953-976, 2010.
%
%    See also HYPOCT, ID, RSKELF_CHOLMV, RSKELF_CHOLSV, RSKELF_DIAG,
%    RSKELF_LOGDET, RSKELF_MV, RSKELF_SPDIAG, RSKELF_SV.

function F = rskelf(A,x,occ,rank_or_tol,pxyfun,opts)

  % set default parameters
  if nargin < 5, pxyfun = []; end
  if nargin < 6, opts = []; end
  if ~isfield(opts,'lvlmax'), opts.lvlmax = Inf; end
  if ~isfield(opts,'ext'), opts.ext = []; end
  if ~isfield(opts,'symm'), opts.symm = 'n'; end
  if ~isfield(opts,'verb'), opts.verb = 0; end

  % check inputs
  opts.symm = chksymm(opts.symm);
  if opts.symm == 'h' && isoctave()
    warning('FLAM:rskelf:octaveLDL','No LDL decomposition in Octave; using LU.')
    opts.symm = 'n';
  end

  % print header
  if opts.verb
    fprintf([repmat('-',1,69) '\n'])
    fprintf('%3s | %6s | %19s | %19s | %10s\n', ...
            'lvl','nblk','start/end npts','start/end npts/blk','time (s)')
    fprintf([repmat('-',1,69) '\n'])
  end

  % build tree
  N = size(x,2);
  ts = tic;
  t = hypoct(x,occ,opts.lvlmax,opts.ext);
  te = toc(ts);
  if opts.verb, fprintf('%3s | %63.2e\n','t',te); end

  % count nonempty boxes at each level
  pblk = zeros(t.nlvl+1,1);
  for lvl = 1:t.nlvl
    pblk(lvl+1) = pblk(lvl);
    for i = t.lvp(lvl)+1:t.lvp(lvl+1)
      if ~isempty(t.nodes(i).xi), pblk(lvl+1) = pblk(lvl+1) + 1; end
    end
  end

  % initialize
  nbox = t.lvp(end);
  e = cell(nbox,1);
  F = struct('sk',e,'rd',e,'T',e,'L',e,'U',e,'p',e,'E',e,'F',e);
  F = struct('N',N,'nlvl',t.nlvl,'lvp',zeros(1,t.nlvl+1),'factors',F,'symm', ...
             opts.symm);
  nlvl = 0;
  n = 0;
  rem = true(N,1);   % which points remain?
  M = cell(nbox,1);  % storage for modified diagonal blocks
  P = zeros(N,1);    % auxiliary array for indexing

  % loop over tree levels
  for lvl = t.nlvl:-1:1
    ts = tic;
    nlvl = nlvl + 1;
    nrem1 = sum(rem);  % remaining points at start
    l = t.l(:,lvl);

    % pull up skeletons from children
    for i = t.lvp(lvl)+1:t.lvp(lvl+1)
      t.nodes(i).xi = [t.nodes(i).xi [t.nodes(t.nodes(i).chld).xi]];
    end

    % loop over nodes
    for i = t.lvp(lvl)+1:t.lvp(lvl+1)
      slf = t.nodes(i).xi;
      nbr = [t.nodes(t.nodes(i).nbor).xi];
      nslf = length(slf);

      % generate modified diagonal block
      M{i} = full(A(slf,slf));
      if lvl < t.nlvl
        P(slf) = 1:nslf;
        for j = t.nodes(i).chld
          k = P(t.nodes(j).xi);
          M{i}(k,k) = M{j};  % overwrite subblock from child
          M{j} = [];         % clear child storage
        end
      end

      % compute proxy interactions and subselect neighbors
      Kpxy = zeros(0,nslf);
      if lvl > 2
        if isempty(pxyfun), nbr = setdiff(find(rem),slf);
        else, [Kpxy,nbr] = pxyfun(x,slf,nbr,l,t.nodes(i).ctr);
        end
      end

      % compress off-diagonal block
      K = full(A(nbr,slf));
      if opts.symm == 'n', K = [K; full(A(slf,nbr))']; end
      K = [K; Kpxy];
      [sk,rd,T] = id(K,rank_or_tol);

      % move on if no compression
      if isempty(rd), continue; end

      % compute factors
      K = M{i};
      if opts.symm == 's', K(rd,:) = K(rd,:) - T.'*K(sk,:);
      else,                K(rd,:) = K(rd,:) - T' *K(sk,:);
      end
      K(:,rd) = K(:,rd) - K(:,sk)*T;
      if opts.symm == 'n' || opts.symm == 's'
        [L,U,p] = lu(K(rd,rd),'vector');
        E = K(sk,rd)/U;
        G = L\K(rd(p),sk);
      elseif opts.symm == 'h'
        [L,U,p] = ldl(K(rd,rd),'vector');
        U = sparse(U);
        E = (K(sk,rd(p))/L')/U.';
        G = [];
      elseif opts.symm == 'p'
        L = chol(K(rd,rd),'lower');
        E = K(sk,rd)/L';
        U = []; p = []; G = [];
      end

      % update self-interaction
      if     opts.symm == 'h', X = E*(U*E');
      elseif opts.symm == 'p', X = E*E';
      else,                    X = E*G;
      end
      M{i} = M{i}(sk,sk) - X;

      % store matrix factors
      n = n + 1;
      F.factors(n).sk = slf(sk);
      F.factors(n).rd = slf(rd);
      F.factors(n).T = T;
      F.factors(n).L = L;
      F.factors(n).U = U;
      F.factors(n).p = p;
      F.factors(n).E = E;
      F.factors(n).F = G;

      % restrict to skeletons for next level
      t.nodes(i).xi = slf(sk);
      rem(slf(rd)) = 0;
    end
    F.lvp(nlvl+1) = n;
    te = toc(ts);

    % print summary
    if opts.verb
      nrem2 = sum(rem);                              % remaining points at end
      nblk = pblk(lvl) + t.lvp(lvl+1) - t.lvp(lvl);  % nonempty up to this level
      fprintf('%3d | %6d | %8d | %8d | %8.2f | %8.2f | %10.2e\n', ...
              lvl,nblk,nrem1,nrem2,nrem1/nblk,nrem2/nblk,te)
    end
  end

  % finish
  F.factors = F.factors(1:n);
  if opts.verb, fprintf([repmat('-',1,69) '\n']), end
end