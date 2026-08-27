import {
  createApiFactory,
  discoveryApiRef,
  fetchApiRef,
} from '@backstage/core-plugin-api';

import { connectivityLinkOpsApiRef, ConnectivityLinkOpsClient } from './api';

export const connectivityLinkOpsApiFactory = createApiFactory({
  api: connectivityLinkOpsApiRef,
  deps: { discoveryApi: discoveryApiRef, fetchApi: fetchApiRef },
  factory: ({ discoveryApi, fetchApi }) =>
    new ConnectivityLinkOpsClient({ discoveryApi, fetchApi }),
});
