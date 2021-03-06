% MF_MV_NC  Dispatch for MF_MV with F.SYMM = 'N' and TRANS = 'C'.

function Y = mf_mv_nc(F,X)

  % initialize
  n = F.lvp(end);
  Y = X;

  % upward sweep
  for i = 1:n
    sk = F.factors(i).sk;
    rd = F.factors(i).rd;
    Y(rd,:) = F.factors(i).L'*Y(rd(F.factors(i).p),:);
    Y(rd,:) = Y(rd,:) + F.factors(i).E'*Y(sk,:);
  end

  % downward sweep
  for i = n:-1:1
    sk = F.factors(i).sk;
    rd = F.factors(i).rd;
    Y(sk,:) = Y(sk,:) + F.factors(i).F'*Y(rd,:);
    Y(rd,:) = F.factors(i).U'*Y(rd,:);
  end
end