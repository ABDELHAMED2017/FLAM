% HIFDE2  Hierarchical interpolative factorization for differential equations
%         with nearest-neighbor interactions on a regular mesh in 2D.
%
%    This is an optimization of HIFDE2X for the special case of nearest-neighbor
%    interactions on a regular mesh. A given mesh node is allowed to interact
%    only with itself and its eight immediate neighbors, thus yielding width-one
%    separators in the multifrontal tree. Matrix indices are assigned to the
%    nodes according to the natural ordering.
%
%    Typical complexity for N = SIZE(A,1) = SIZE(A,2): O(N).
%
%    F = HIFDE2(A,N,OCC,RANK_OR_TOL) produces a factorization F of the matrix A
%    acting on the nodes of a regular (N-1) x (N-1) mesh of the unit square with
%    leaf size (OCC-1) x (OCC-1) and local precision parameter RANK_OR_TOL. See
%    ID for details.
%
%    F = HIFDE2(A,N,OCC,RANK_OR_TOL,OPTS) also passes various options to the
%    algorithm. See HIFDE2X for details.
%
%    See also HIFDE2X, HIFDE3, HIFDE3X, HIFDE_CHOLMV, HIFDE_CHOLSV, HIFDE_DIAG,
%    HIFDE_LOGDET, HIFDE_MV, HIFDE_SPDIAG, HIFDE_SV, ID.

function F = hifde2(A,n,occ,rank_or_tol,opts)

  % set default parameters
  if nargin < 5, opts = []; end
  if ~isfield(opts,'lvlmax'), opts.lvlmax = Inf; end
  if ~isfield(opts,'skip'), opts.skip = 0; end
  if ~isfield(opts,'symm'), opts.symm = 'n'; end
  if ~isfield(opts,'verb'), opts.verb = 0; end

  % check inputs
  assert(n > 0,'FLAM:hifde2:invalidMeshSize','Mesh size must be positive.')
  assert(occ > 0,'FLAM:hifde2:invalidOcc','Leaf occupancy must be positive.')
  assert(opts.lvlmax >= 1,'FLAM:hifde2:invalidLvlmax', ...
         'Maximum tree depth must be at least 1.')
  assert(opts.skip >= 0,'FLAM:hifde2:invalidSkip', ...
         'Skip parameter must be nonnegative.')
  opts.symm = chksymm(opts.symm);
  if opts.symm == 'h' && isoctave()
    warning('FLAM:hifde2:octaveLDL','No LDL decomposition in Octave; using LU.')
    opts.symm = 'n';
  end

  % print header
  if opts.verb
    fprintf([repmat('-',1,71) '\n'])
    fprintf('%5s | %6s | %19s | %19s | %10s\n', ...
            'lvl','nblk','start/end npts','start/end npts/blk','time (s)')
    fprintf([repmat('-',1,71) '\n'])
  end

  % initialize
  nd = n - 1;  % number of mesh nodes in one dimension
  N = nd^2;    % total number of nodes
  nlvl = min(opts.lvlmax,ceil(max(0,log2(n/occ)))+1);  % number of tree levels
  mn = (4^nlvl - 1)/3;  % maximum capacity for matrix factors
  e = cell(mn,1);
  F = struct('sk',e,'rd',e,'T',e,'L',e,'U',e,'p',e,'E',e,'F',e);
  F = struct('N',N,'nlvl',nlvl,'lvp',zeros(1,nlvl+1),'factors',F,'symm', ...
             opts.symm);
  nlvl = 0;
  nf = 0;
  grd = reshape(1:N,nd,nd);  % index mapping to each node
  rem = true(nd,nd);         % which nodes remain?
  nz = 128;                  % initial capacity for sparse matrix updates
  I = zeros(nz,1);
  J = zeros(nz,1);
  V = zeros(nz,1);

  % set initial width
  w = n;
  for lvl = 1:F.nlvl, w = ceil(w/2); end

  % loop over tree levels
  for lvl = F.nlvl:-1:1
    w = 2*w;          % cell width
    nb1 = ceil(n/w);  % number of cells in each dimension

    % loop over dimensions
    for d = [2 1]
      ts = tic;
      nrem1 = sum(rem(:));  % remaining nodes at start
      nb = 0;               % number of centers

      % block elimination
      if d == 2
        nblk = nb1^2;  % number of cells
        e = cell(nblk,1);
        blocks = struct('slf',e,'sk',e,'rd',e,'T',e);

        % loop over cells
        for i = 1:nb1, for j = 1:nb1

          % set up indices
          ia = (i - 1)*w;
          ib =  i     *w;
          is = max(1,ia):min(nd,ib);
          ja = (j - 1)*w;
          jb =  j     *w;
          js = max(1,ja):min(nd,jb);

          % initialize local data
          slf = grd(is,js);
          slf = slf(rem(is,js));
          slf = slf(:)';
          idx = slf - 1;
          jj = floor(idx/nd);
          ii = idx - nd*jj;
          ii = ii + 1;
          jj = jj + 1;

          % eliminate interior nodes
          in = ii ~= ia & ii ~= ib & jj ~= ja & jj ~= jb;
          sk = find(~in);
          rd = find( in);
          sk = sk(:)';
          rd = rd(:)';

          % move on if no compression
          if isempty(rd), continue; end
          rem(slf(rd)) = 0;

          % store data
          nb = nb + 1;
          blocks(nb).slf = slf;
          blocks(nb).sk = sk;
          blocks(nb).rd = rd;
        end, end

      % skeletonization
      else
        if lvl == 1, break; end                     % done if at root
        if lvl > F.nlvl - opts.skip, continue; end  % continue if in skip stage

        % initialize
        nblk = 2*nb1*(nb1 - 1);  % number of edges
        e = cell(nblk,1);
        blocks = struct('slf',e,'sk',e,'rd',e,'T',e);

        % loop over edges
        for i = 1:2*nb1-1, for j = 1:2*nb1-1
          mi = ~mod(i,2);  % half-offset in each dimension?
          mj = ~mod(j,2);
          if mi + mj ~= 1, continue; end  % not an edge

          % set up indices
          ib = floor(i/2);
          jb = floor(j/2);
          if mi
            is = ib*w;
            in = ib*w + (-w:w);
            js = jb*w + (1:w-1);
            jn = jb*w + (0:w  );
          elseif mj
            is = ib*w + (1:w-1);
            in = ib*w + (0:w  );
            js = jb*w;
            jn = jb*w + (-w:w);
          end

          % restrict to domain
          is = is(is > 0 & is < n);
          in = in(in > 0 & in < n);
          js = js(js > 0 & js < n);
          jn = jn(jn > 0 & jn < n);

          % initialize local data
          slf = grd(is,js);
          slf = slf(rem(is,js));
          slf = slf(:)';
          nbr = grd(in,jn);
          nbr = nbr(rem(in,jn));
          nbr = nbr(:)';
          nbr = nbr(~ismemb(nbr,slf));

          % compress off-diagonal block
          K = spget(A,nbr,slf);
          if opts.symm == 'n', K = [K; spget(A,slf,nbr)']; end
          [sk,rd,T] = id(K,rank_or_tol);

          % move on if no compression
          if isempty(rd), continue; end
          rem(slf(rd)) = 0;

          % store data
          nb = nb + 1;
          blocks(nb).slf = slf;
          blocks(nb).sk = sk;
          blocks(nb).rd = rd;
          blocks(nb).T = T;
        end, end
      end
      blocks = blocks(1:nb);

      % initialize for factorization
      nlvl = nlvl + 1;
      nz = 0;

      % loop over stored blocks
      for i = 1:nb
        slf = blocks(i).slf;
        sk = blocks(i).sk;
        rd = blocks(i).rd;
        T = blocks(i).T;

        % compute factors
        K = spget(A,slf,slf);
        if ~isempty(T)
          if opts.symm == 's', K(rd,:) = K(rd,:) - T.'*K(sk,:);
          else,                K(rd,:) = K(rd,:) - T' *K(sk,:);
          end
          K(:,rd) = K(:,rd) - K(:,sk)*T;
        end
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
        if     opts.symm == 'h', X = -E*(U*E');
        elseif opts.symm == 'p', X = -E*E';
        else,                    X = -E*G;
        end
        [I_,J_] = ndgrid(slf(sk));
        [I,J,V,nz] = sppush3(I,J,V,nz,I_,J_,X);

        % store matrix factors
        nf = nf + 1;
        if mn < nf
          e = cell(mn,1);
          s = struct('sk',e,'rd',e,'T',e,'L',e,'U',e,'p',e,'E',e,'F',e);
          F.factors = [F.factors; s];
          mn = 2*mn;
        end
        F.factors(nf).sk = slf(sk);
        F.factors(nf).rd = slf(rd);
        F.factors(nf).T = T;
        F.factors(nf).L = L;
        F.factors(nf).U = U;
        F.factors(nf).p = p;
        F.factors(nf).E = E;
        F.factors(nf).F = G;
      end
      F.lvp(nlvl+1) = nf;

      % update modified entries
      [I_,J_,V_] = find(A);
      idx = rem(I_) & rem(J_);
      [I,J,V,nz] = sppush3(I,J,V,nz,I_(idx),J_(idx),V_(idx));
      A = sparse(I(1:nz),J(1:nz),V(1:nz),N,N);
      te = toc(ts);

      % print summary
      if opts.verb
        nrem2 = sum(rem(:));  % remaining nodes at end
        fprintf('%3d-%1d | %6d | %8d | %8d | %8.2f | %8.2f | %10.2e\n', ...
                lvl,d,nblk,nrem1,nrem2,nrem1/nblk,nrem2/nblk,te)
      end
    end
  end

  % finish
  F.nlvl = nlvl;
  F.lvp = F.lvp(1:nlvl+1);
  F.factors = F.factors(1:nf);
  if opts.verb, fprintf([repmat('-',1,71) '\n']); end
end