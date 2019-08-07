% MFX  Multifrontal factorization.
%
%    This is an implementation of the nested dissection multifrontal method in
%    the style of the recursive skeletonization factorization; indeed, both can
%    be viewed in the same algorithmic framework, with the former specialized to
%    sparse matrices and the latter to structured dense matrices. It is not
%    meant to replace or outperform the native MATLAB sparse matrix routines,
%    but rather to provide a basis for the development of more advanced
%    algorithms as well as a reference against which to benchmark them.
%
%    Given a square matrix A with full-rank diagonal blocks, this algorithm
%    factorizes it as a multilevel LU, LDL, or Cholesky decomposition. Such a
%    representation facilitates fast inversion, determinant computation, and
%    selected inversion, among other operations.
%
%    Each row/column of A is associated with a point, with identical row/column
%    indices corresponding to the same point. The induced point geometry defines
%    the multifrontal tree, with "interior" points having no exterior
%    interactions hierarchically eliminated at each level.
%
%    Typical complexity for N = SIZE(A,1) = SIZE(A,2): O(N) in 1D and
%    O(N^(3*(1 - 1/D))) in D dimensions.
%
%    See MF2 and MF3 for optimized versions specialized for nearest-neighbor
%    interactions on regular meshes in 2D and 3D, respectively.
%
%    F = MFX(A,X,OCC) produces a factorization F of the matrix A acting on the
%    points X using tree occupancy parameter OCC. See HYPOCT for details.
%
%    F = MFX(A,X,OCC,OPTS) also passes various options to the algorithm. Valid
%    options include:
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
%    References:
%
%      I.S. Duff, J.K. Reid. The multifrontal solution of indefinite sparse
%        symmetric linear equations. ACM Trans. Math. Softw. 9 (3): 302-325,
%        1983.
%
%      A. George. Nested dissection of a regular finite element mesh. SIAM J.
%        Numer. Anal. 10 (2): 345-363, 1973.
%
%      B.M. Irons. A frontal solution program for finite element analysis. Int.
%        J. Numer. Meth. Eng. 2: 5-32, 1970.
%
%    See also HYPOCT, MF2, MF3, MF_CHOLMV, MF_CHOLSV, MF_DIAG, MF_LOGDET, MF_MV,
%    MF_SPDIAG, MF_SV.

function F = mfx(A,x,occ,opts)

  % set default parameters
  if nargin < 4, opts = []; end
  if ~isfield(opts,'lvlmax'), opts.lvlmax = Inf; end
  if ~isfield(opts,'ext'), opts.ext = []; end
  if ~isfield(opts,'symm'), opts.symm = 'n'; end
  if ~isfield(opts,'verb'), opts.verb = 0; end

  % check inputs
  assert(strcmpi(opts.symm,'n') || strcmpi(opts.symm,'s') || ...
         strcmpi(opts.symm,'h') || strcmpi(opts.symm,'p'), ...
         'FLAM:mfx:invalidSymm', ...
         'Symmetry parameter must be one of ''N'', ''S'', ''H'', or ''P''.')
  if strcmpi(opts.symm,'h') && isoctave()
    warning('FLAM:mfx:octaveLDL','No LDL decomposition in Octave; using LU.')
    opts.symm = 's';
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
      if ~isempty(t.nodes(i).xi)
        pblk(lvl+1) = pblk(lvl+1) + 1;
      end
    end
  end

  % initialize
  nbox = t.lvp(end);
  e = cell(nbox,1);
  F = struct('sk',e,'rd',e,'L',e,'U',e,'p',e,'E',e,'F',e);
  F = struct('N',N,'nlvl',t.nlvl,'lvp',zeros(1,t.nlvl+1),'factors',F,'symm', ...
             opts.symm);
  nlvl = 0;
  n = 0;
  rem = true(N,1);   % which points remain?
  mnz = 128;         % maximum capacity for sparse matrix updates
  I = zeros(mnz,1);
  J = zeros(mnz,1);
  S = zeros(mnz,1);

  % loop over tree levels
  for lvl = t.nlvl:-1:1
    ts = tic;
    nlvl = nlvl + 1;
    nrem1 = sum(rem);  % remaining points at start
    nz = 0;

    % form matrix transpose for fast row access
    if strcmpi(opts.symm,'n'), Ac = A'; end

    % pull up skeletons from children
    for i = t.lvp(lvl)+1:t.lvp(lvl+1)
      t.nodes(i).xi = unique([t.nodes(i).xi [t.nodes(t.nodes(i).chld).xi]]);
    end

    % loop over nodes
    for i = t.lvp(lvl)+1:t.lvp(lvl+1)
      slf = t.nodes(i).xi;
      sslf = sort(slf);

      % skeletonize -- i.e., keep only points with exterior interactions
      [I_,J_] = find(A(:,slf));
      idx = ~ismemb(I_,sslf);
      I_ = I_(idx);
      J_ = J_(idx);
      if strcmpi(opts.symm,'n')
        [Ic,Jc] = find(Ac(:,slf));
        idx = ~ismemb(Ic,sslf);
        Ic = Ic(idx);
        Jc = Jc(idx);
        I_ = [I_(:); Ic(:)];
        J_ = [J_(:); Jc(:)];
        [J_,idx] = sort(J_);
        I_ = I_(idx);
      end
      sk = unique(J_)';

      % optimize by sharing skeletons among neighbors (thin separators)
      nbr = t.nodes(i).nbor;
      nbr = nbr(nbr < i);  % restrict to already processed neighbors
      if ~isempty(nbr)
        nbr = sort([t.nodes(nbr).xi]);
        isnbr = ismemb(I_,nbr);
        p = [0; find(diff(J_)); length(J_)];  % indexing array for interaction
        % indices, i.e., I_(P(SK)+1:P(SK+1)) corresponds to skeleton SK

        % remove those made redundant by neighbor skeletons
        nsk = length(sk);
        keep = true(length(sk),1);
        nbrsk = [];  % neighbor skeletons to share
        for j = 1:nsk
          if ~all(isnbr(p(j)+1:p(j+1))), continue; end  % redundant if interacts
          keep(j) = false;                              % ... only with neighbor
          nbrsk = [nbrsk I_(p(j)+1:p(j+1))'];           % ... skeletons
        end
        nbrsk = unique(nbrsk);
        % prune self-skeletons and add neighbor-skeletons
        sk = [sk(keep) length(slf)+(1:length(nbrsk))];
        slf = [slf nbrsk];
      end

      % restrict to skeletons for next level
      t.nodes(i).xi = slf(sk);  % note: can expand due to neighbor sharing
      rd = find(~ismemb(1:length(slf),sort(sk)));

      % move on if no compression
      if isempty(rd), continue; end
      rem(slf(rd)) = 0;

      % compute factors
      K = spget(A,slf,slf);
      if strcmpi(opts.symm,'n') || strcmpi(opts.symm,'s')
        [L,U,p] = lu(K(rd,rd),'vector');
        E = K(sk,rd)/U;
        G = L\K(rd(p),sk);
      elseif strcmpi(opts.symm,'h')
        [L,U,p] = ldl(K(rd,rd),'vector');
        U = diag(U);
        E = (K(sk,rd(p))/L')./U.';
        G = [];
      elseif strcmpi(opts.symm,'p')
        L = chol(K(rd,rd),'lower');
        E = K(sk,rd)/L';
        U = []; p = []; G = [];
      end

      % update self-interaction
      if     strcmpi(opts.symm,'h'), S_ = -E*(U.*E');
      elseif strcmpi(opts.symm,'p'), S_ = -E*E';
      else,                          S_ = -E*G;
      end
      [I_,J_] = ndgrid(slf(sk));
      m = length(sk)^2;
      nz_new = nz + m;
      if mnz < nz_new
        while mnz < nz_new, mnz = 2*mnz; end
        e = zeros(mnz-length(I),1);
        I = [I; e];
        J = [J; e];
        S = [S; e];
      end
      I(nz+1:nz+m) = I_(:);
      J(nz+1:nz+m) = J_(:);
      S(nz+1:nz+m) = S_(:);
      nz = nz + m;

      % store matrix factors
      n = n + 1;
      F.factors(n).sk = slf(sk);
      F.factors(n).rd = slf(rd);
      F.factors(n).L = L;
      F.factors(n).U = U;
      F.factors(n).p = p;
      F.factors(n).E = E;
      F.factors(n).F = G;
    end
    F.lvp(nlvl+1) = n;

    % update sparse matrix
    [I_,J_,S_] = find(A);     % pull existing entries
    idx = rem(I_) & rem(J_);  % keep only those needed for next level
    I_ = I_(idx);
    J_ = J_(idx);
    S_ = S_(idx);
    m = length(S_);
    nz_new = mnz + m;
    if mnz < nz_new
      while mnz < nz_new, mnz = 2*mnz; end
      e = zeros(mnz-length(I),1);
      I = [I; e];
      J = [J; e];
      S = [S; e];
    end
    I(nz+1:nz+m) = I_;        % apply on top of queued updates
    J(nz+1:nz+m) = J_;
    S(nz+1:nz+m) = S_;
    nz = nz + m;
    A = sparse(I(1:nz),J(1:nz),S(1:nz),N,N);
    te = toc(ts);

    % print summary
    if opts.verb
      nrem2 = sum(rem);  % remaining points at end
      nblk = pblk(lvl) + t.lvp(lvl+1) - t.lvp(lvl);  % nonempty up to this level
      fprintf('%3d | %6d | %8d | %8d | %8.2f | %8.2f | %10.2e\n', ...
              lvl,nblk,nrem1,nrem2,nrem1/nblk,nrem2/nblk,te)
    end
  end

  % finish
  F.factors = F.factors(1:n);
  if opts.verb, fprintf([repmat('-',1,69) '\n']); end
end