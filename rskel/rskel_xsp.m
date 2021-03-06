% RSKEL_XSP  Extended sparsification for recursive skeletonization.
%
%    A = RSKEL_XSP(F) produces the extended sparse embedding A of the compressed
%    matrix F. If F has the single-level representation D + U*S*V', then
%
%          [D   U   ]
%      A = [V'    -I]
%          [   -I  S]
%
%    where I is an identity matrix of the appropriate size; in the multilevel
%    setting, S itself is expanded in the same way. This can be used to solve
%    linear systems and least squares problems.
%
%    If F.SYMM = 'N', then the entire extended sparse matrix is returned;
%    otherwise, only the lower triangular part is returned.
%
%    Typical complexity: same as RSKEL_MV.
%
%    See also RSKEL.

function A = rskel_xsp(F)

  % initialize
  nlvl = F.nlvl;
  M = 0;
  N = 0;

  % allocate storage
  rrem = true(F.M,1);
  crem = true(F.N,1);
  nz = 0;  % total number of nonzeros
  for lvl = 1:nlvl
    for i = F.lvpd(lvl)+1:F.lvpd(lvl+1), nz = nz + numel(F.D(i).D); end
    for i = F.lvpu(lvl)+1:F.lvpu(lvl+1)
      rrem(F.U(i).rrd) = 0;
      if F.symm == 'n'
        crem(F.U(i).crd) = 0;
        nz = nz + numel(F.U(i).rT) + numel(F.U(i).cT);
      else
        crem(F.U(i).rrd) = 0;
        nz = nz + numel(F.U(i).rT);
      end
    end
    if F.symm == 'n', nz = nz + 2*(sum(rrem) + sum(crem));
    else,             nz = nz +    sum(rrem) + sum(crem);
    end
  end
  I = zeros(nz,1);
  J = zeros(nz,1);
  S = zeros(nz,1);
  nz = 0;
  rrem(:) = 1;
  crem(:) = 1;

  % loop over levels
  for lvl = 1:nlvl

    % compute index data
    prrem1 = cumsum(rrem);
    pcrem1 = cumsum(crem);
    for i = F.lvpu(lvl)+1:F.lvpu(lvl+1)
      rrem(F.U(i).rrd) = 0;
      if F.symm == 'n', crem(F.U(i).crd) = 0;
      else,             crem(F.U(i).rrd) = 0;
      end
    end
    prrem2 = cumsum(rrem);
    pcrem2 = cumsum(crem);
    rn = prrem1(end);
    cn = pcrem1(end);
    rk = prrem2(end);
    ck = pcrem2(end);

    % embed diagonal matrices
    for i = F.lvpd(lvl)+1:F.lvpd(lvl+1)
      [j,k] = ndgrid(F.D(i).i,F.D(i).j);
      D = F.D(i).D;
      m = numel(D);
      I(nz+1:nz+m) = M + prrem1(j(:));
      J(nz+1:nz+m) = N + pcrem1(k(:));
      S(nz+1:nz+m) = D(:);
      nz = nz + m;
    end

    % terminate if at root
    if lvl == nlvl
      M = M + rn;
      N = N + cn;
      break
    end

    % embed interpolation identity matrices
    if F.symm == 'n'
      I(nz+1:nz+rk) = M + prrem1(find(rrem));
      J(nz+1:nz+rk) = N + cn + prrem2(find(rrem));
      S(nz+1:nz+rk) = ones(rk,1);
      nz = nz + rk;
    end
    I(nz+1:nz+ck) = M + rn + pcrem2(find(crem));
    J(nz+1:nz+ck) = N + pcrem1(find(crem));
    S(nz+1:nz+ck) = ones(ck,1);
    nz = nz + ck;

    % embed interpolation matrices
    for i = F.lvpu(lvl)+1:F.lvpu(lvl+1)
      rrd = F.U(i).rrd;
      rsk = F.U(i).rsk;
      rT  = F.U(i).rT;
      if F.symm == 'n'
        crd = F.U(i).crd;
        csk = F.U(i).csk;
        cT  = F.U(i).cT;
      elseif F.symm == 's'
        crd = F.U(i).rrd;
        csk = F.U(i).rsk;
        cT  = F.U(i).rT.';
      elseif F.symm == 'h'
        crd = F.U(i).rrd;
        csk = F.U(i).rsk;
        cT  = F.U(i).rT';
      end

      % row interpolation
      if F.symm == 'n'
        [j,k] = ndgrid(rrd,rsk);
        m = numel(rT);
        I(nz+1:nz+m) = M + prrem1(j(:));
        J(nz+1:nz+m) = N + cn + prrem2(k(:));
        S(nz+1:nz+m) = rT(:);
        nz = nz + m;
      end

      % column interpolation
      [j,k] = ndgrid(csk,crd);
      m = numel(cT);
      I(nz+1:nz+m) = M + rn + pcrem2(j(:));
      J(nz+1:nz+m) = N + pcrem1(k(:));
      S(nz+1:nz+m) = cT(:);
      nz = nz + m;
    end

    % embed identity matrices
    M = M + rn;
    N = N + cn;
    if F.symm == 'n'
      I(nz+1:nz+ck) = M + (1:ck);
      J(nz+1:nz+ck) = N + rk + (1:ck);
      S(nz+1:nz+ck) = -ones(ck,1);
      nz = nz + ck;
    end
    I(nz+1:nz+rk) = M + ck + (1:rk);
    J(nz+1:nz+rk) = N + (1:rk);
    S(nz+1:nz+rk) = -ones(rk,1);
    nz = nz + rk;

    % move pointer to next level
    M = M + ck;
    N = N + rk;
  end

  % assemble sparse matrix
  if F.symm ~= 'n'
    idx = I >= J;
    I = I(idx);
    J = J(idx);
    S = S(idx);
  end
  A = sparse(I,J,S,M,N);
end