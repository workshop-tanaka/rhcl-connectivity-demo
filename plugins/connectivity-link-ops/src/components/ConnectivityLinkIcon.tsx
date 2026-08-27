import React from 'react';
import { SvgIcon, SvgIconProps } from '@material-ui/core';

/**
 * Duas rotas convergindo num ponto de controle — a leitura mais curta do que o
 * Connectivity Link faz. Herda currentColor, então acompanha o tema do RHDH.
 */
export const ConnectivityLinkIcon = (props: SvgIconProps) => (
  <SvgIcon {...props} viewBox="0 0 24 24">
    <path
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      d="M3 6h4c3 0 3 6 6 6M3 18h4c3 0 3-6 6-6"
    />
    <circle cx="17" cy="12" r="3" fill="none" stroke="currentColor" strokeWidth="1.8" />
    <circle cx="3" cy="6" r="1.4" fill="currentColor" />
    <circle cx="3" cy="18" r="1.4" fill="currentColor" />
  </SvgIcon>
);
