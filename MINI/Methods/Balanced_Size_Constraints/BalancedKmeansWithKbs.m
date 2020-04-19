function [ MSE_best,re ] = BalancedKmeansWithKbs( data,k,nb )  
%matrix b is the row vector contains the points count that you want
%initial some basic parameter
    MSE_best=inf;
    sumError=0;
    na=[];             %count the points number of each cluster
    [dataLength,~]=size(data);
    a=zeros(dataLength,k);
    re=zeros(dataLength,1);
    %run kmeans and idData is the column vector contains label of each point
    [idData,centroids]=kmeans(data,k);      
    for i=1:k
        na(i)=sum(idData(:,1)==i);
    end
    factor=-1./sqrt(na.*nb);
    for i=1:dataLength
        a(i,idData(i))=1;   %matrix a currently be the factor of objective function
    end
    for i=1:k
        a(:,i)=a(:,i)*factor(i);
    end
    assignment=KbsAssignment(a',nb);
    %�����ǩ���ֵ
    for i=1:k
        re(find(assignment(:,i)==1),1)=i;
    end
    %calculate MSE
    for i=1:k
        clusterData=find(assignment(:,i)==1);
        for j=clusterData'
            sumError=sumError+(centroids(i,:)-data(j,:))*(centroids(i,:)-data(j,:))';
        end
    end
    MSE_best=sumError/dataLength;
end
function [ assignment] = KbsAssignment( costMat,nb )
    options = optimoptions('intlinprog','RelativeGapTolerance',0);
    C=costMat';
    [m,n]=size(C);
    f=C(:);
    intcon=(1:m*n)';
    %��ʽԼ������
    Aeq=sparse(m,m*n);
    for i=1:n
        Aeq(1:m,1+(i-1)*m:i*m)=speye(m,m);
    end
    beq=ones(m,1);
    %����ʽԼ������
    A=sparse(n*2,m*n);
    for i=1:n
        A(i,1+(i-1)*m:i*m)=ones(1,m)*-1;
    end
    for i=1:n
        A(i+n,1+(i-1)*m:i*m)=ones(1,m);
    end
    b(1:n)=nb'.*-1;
    b(n+1:n*2)=nb;

    lb=zeros(m*n,1);
    ub=ones(m*n,1);
    X=intlinprog(f,intcon,A,b,Aeq,beq,lb,ub,options);
    assignment=reshape(X,m,n);
end

