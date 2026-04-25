export interface IPeer {
    addr: string;
    addrlocal: string;
    network: string;
    protocol: string;
    inbound: boolean;
    reputation: number;
    bytessent: number;
    bytesrecv: number;
    objsent: number;
    objrecv: number;
    createtime: number;
}
