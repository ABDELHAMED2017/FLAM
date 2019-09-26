% MF3  Multifrontal factorization for nearest-neighbor interactions on a
%      regular mesh in 3D.
%
%    This is an optimization of MFX for the special case of nearest-neighbor
%    interactions on a regular mesh in 2D. A given mesh node is allowed to
%    interact only with itself and its 26 immediate neighbors, thus yielding
%    width-one separators in the multifrontal tree. Matrix indices are assigned
%    to the nodes according to the natural ordering.
%
%    Typical complexity for N = SIZE(A,1) = SIZE(A,2): O(N^2).
%
%    F = MF2(A,N,OCC) produces a factorization F of the matrix A acting on the
%    nodes of a regular (N-1) x (N-1) x (N-1) mesh of the unit cube with leaf
%    size (OCC-1) x (OCC-1) x (OCC-1).
%
%    F = MF3(A,N,OCC,OPTS) also passes various options to the algorithm. See MFX
%    for details.
%
%    See also MF2, MF_CHOLMV, MF_CHOLSV, MF_DIAG, MF_LOGDET, MF_MV, MF_SPDIAG,
%    MF_SV, MFX.

function F = mf3(A,n,occ,opts)

  % set default parameters
  if nargin < 4, opts = []; end
  if ~isfield(opts,'lvlmax'), opts.lvlmax = Inf; end
  if ~isfield(opts,'symm'), opts.symm = 'n'; end
  if ~isfield(opts,'verb'), opts.verb = 0; end

  % check inputs
  assert(n > 0,'FLAM:mf3:invalidMeshSize','Mesh size must be positive.')
  assert(occ > 0,'FLAM:mf3:invalidOcc','Leaf occupancy must be positive.')
  assert(opts.lvlmax >= 1,'FLAM:mf2:invalidLvlmax', ...
         'Maximum tree depth must be at least 1.')
  assert(strcmpi(opts.symm,'n') || strcmpi(opts.symm,'s') || ...
         strcmpi(opts.symm,'h') || strcmpi(opts.symm,'p'), ...
         'FLAM:mf3:invalidSymm', ...
         'Symmetry parameter must be one of ''N'', ''S'', ''H'', or ''P''.')
  if strcmpi(opts.symm,'h') && isoctave()
    warning('FLAM:mf3:octaveLDL','No LDL decomposition in Octave; using LU.')
    opts.symm = 'n';
  end

  % print header
  if opts.verb
    fprintf([repmat('-',1,69) '\n'])
    fprintf('%3s | %6s | %19s | %19s | %10s\n', ...
            'lvl','nblk','start/end npts','start/end npts/blk','time (s)')
    fprintf([repmat('-',1,69) '\n'])
  end

  % initialize
  nd = n - 1;  % number of mesh nodes in one dimension
  N = nd^3;    % total number of nodes
  nlvl = min(opts.lvlmax,ceil(max(0,log2(n/occ)))+1);  % number of tree levels
  nbox = (8^nlvl - 1)/7;  % number of factors in multifrontal tree
  e = cell(nbox,1);
  F = struct('sk',e,'rd',e,'L',e,'U',e,'p',e,'E',e,'F',e);
  F = struct('N',N,'nlvl',nlvl,'lvp',zeros(1,nlvl+1),'factors',F,'symm', ...
             opts.symm);
  nlvl = 0;
  nf = 0;
  grd = reshape(1:N,nd,nd,nd);  % index mapping to each node
  rem = true(nd,nd,nd);         % which nodes remain?
  nz = 128;                     % initial capacity for sparse matrix updates
  I = zeros(nz,1);
  J = zeros(nz,1);
  V = zeros(nz,1);

  % set initial width
  w = n;
  for lvl = 1:F.nlvl, w = ceil(w/2); end

  % loop over tree levels
  for lvl = F.nlvl:-1:1
    ts = tic;
    nlvl = nlvl + 1;
    w = 2*w;              % cell width
    nb = ceil(n/w);       % number of cells in each dimension
    nrem1 = sum(rem(:));  % remaining nodes at start
    nz = 0;

    % loop over cells
    for i = 1:nb, for j = 1:nb, for k = 1:nb

      % set up indices
      ia = (i - 1)*w;
      ib =  i     *w;
      is = max(1,ia):min(nd,ib);
      ja = (j - 1)*w;
      jb =  j     *w;
      js = max(1,ja):min(nd,jb);
      ka = (k - 1)*w;
      kb =  k     *w;
      ks = max(1,ka):min(nd,kb);
      [ii,jj,kk] = ndgrid(is,js,ks);

      % initialize local arrays
      grd_ = grd(is,js,ks);
      rem_ = rem(is,js,ks);
      idx = zeros(size(grd_));
      idx(rem_) = 1:sum(rem_(:));
      slf = grd_(rem_);
      slf = slf(:)';

      % skeletonize, i.e., eliminate interior nodes
      in = ii ~= ia & ii ~= ib & jj ~= ja & jj ~= jb & kk ~= ka & kk ~= kb;
      sk = idx(rem_ & ~in);
      rd = idx(rem_ &  in);
      sk = sk(:)';
      rd = rd(:)';

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
      if     strcmpi(opts.symm,'h'), X = -E*(U.*E');
      elseif strcmpi(opts.symm,'p'), X = -E*E';
      else,                          X = -E*G;
      end
      [I_,J_] = ndgrid(slf(sk));
      [I,J,V,nz] = sppush3(I,J,V,nz,I_,J_,X);

      % store matrix factors
      nf = nf + 1;
      F.factors(nf).sk = slf(sk);
      F.factors(nf).rd = slf(rd);
      F.factors(nf).L = L;
      F.factors(nf).U = U;
      F.factors(nf).p = p;
      F.factors(nf).E = E;
      F.factors(nf).F = G;
    end, end, end
    F.lvp(nlvl+1) = nf;

    % update sparse matrix
    [I_,J_,V_] = find(A);     % pull existing entries
    idx = rem(I_) & rem(J_);  % keep only those needed for next level
    [I,J,V,nz] = sppush3(I,J,V,nz,I_(idx),J_(idx),V_(idx));
    A = sparse(I(1:nz),J(1:nz),V(1:nz),N,N);
    te = toc(ts);

    % print summary
    if opts.verb
      nrem2 = sum(rem(:));  % remaining nodes at end
      nblk = nb^3;
      fprintf('%3d | %6d | %8d | %8d | %8.2f | %8.2f | %10.2e\n', ...
              lvl,nblk,nrem1,nrem2,nrem1/nblk,nrem2/nblk,te)
    end
  end

  % finish
  F.factors = F.factors(1:nf);
  if opts.verb, fprintf([repmat('-',1,69) '\n']); end
end